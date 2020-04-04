import deques

import nodetype
import common

func check(cond: bool, msg: string) =
  if not cond:
    raise newException(RegexError, msg)

type
  Nfa* = seq[Node]
  End = seq[int16]
    ## store all the last
    ## states of a given state.
    ## Avoids having to recurse
    ## a state to find its ends,
    ## but have to keep them up-to-date

func combine(
  nfa: var seq[Node],
  ends: var seq[End],
  org: int16,
  target: int16
) =
  ## combine ends of ``org``
  ## with ``target``
  for e in ends[org]:
    for i, ni in nfa[e].next.mpairs:
      if nfa[ni].kind == reEOE:
        ni = target
  ends[org] = ends[target]

func update(
  ends: var seq[End],
  ni: int16,
  next: openArray[int16]
) =
  ## update the ends of Node ``ni``
  ## to point to ends of ``n.outA``
  ## and ``n.outB``. If either outA
  ## or outB are ``0`` (EOE),
  ## the ends will point to itself
  ends[ni].setLen(0)
  for n in next:
    if n == 0:
        ends[ni].add(ni)
    else:
        ends[ni].add(ends[n])

const eoe = 0'i16

func eNfa(expression: seq[Node]): Nfa {.raises: [RegexError].} =
  ## Thompson's construction
  result = newSeqOfCap[Node](expression.len + 2)
  result.add(initEOENode())
  var
    ends = newSeq[End](expression.len + 1)
    states = newSeq[int16]()
  if expression.len == 0:
    states.add(eoe)
  for n in expression:
    var n = n
    assert n.next.len == 0
    check(
      result.high < int16.high,
      ("The expression is too long, " &
       "limit is ~$#") %% $int16.high)
    let ni = result.len.int16
    case n.kind
    of matchableKind, assertionKind:
      n.next.add(eoe)
      ends.update(ni, [eoe])
      result.add(n)
      states.add(ni)
    of reJoiner:
      let
        stateB = states.pop()
        stateA = states.pop()
      result.combine(ends, stateA, stateB)
      states.add(stateA)
    of reOr:
      check(
        states.len >= 2,
        "Invalid OR conditional, nothing to " &
        "match at right/left side of the condition")
      let
        stateB = states.pop()
        stateA = states.pop()
      n.next.add([stateA, stateB])
      ends.update(ni, n.next)
      result.add(n)
      states.add(ni)
    of reZeroOrMore:
      check(
        states.len >= 1,
        "Invalid `*` operator, " &
        "nothing to repeat")
      let stateA = states.pop()
      n.next.add([stateA, eoe])
      ends.update(ni, n.next)
      result.combine(ends, stateA, ni)
      result.add(n)
      states.add(ni)
      if n.isGreedy:
        swap(result[^1].next[0], result[^1].next[1])
    of reOneOrMore:
      check(
        states.len >= 1,
        "Invalid `+` operator, " &
        "nothing to repeat")
      let stateA = states.pop()
      n.next.add([stateA, eoe])
      ends.update(ni, n.next)
      result.combine(ends, stateA, ni)
      result.add(n)
      states.add(stateA)
      if n.isGreedy:
        swap(result[^1].next[0], result[^1].next[1])
    of reZeroOrOne:
      check(
        states.len >= 1,
        "Invalid `?` operator, " &
        "nothing to make optional")
      let stateA = states.pop()
      n.next.add([stateA, eoe])
      ends.update(ni, n.next)
      result.add(n)
      states.add(ni)
      if n.isGreedy:
        swap(result[^1].next[0], result[^1].next[1])
    of reGroupStart:
      let stateA = states.pop()
      n.next.add(stateA)
      ends.update(ni, n.next)
      result.add(n)
      states.add(ni)
    of reGroupEnd:
      n.next.add(eoe)
      ends.update(ni, n.next)
      let stateA = states.pop()
      result.combine(ends, stateA, ni)
      result.add(n)
      states.add(stateA)
    else:
      assert(false, "Unhandled node: $#" %% $n.kind)
  assert states.len == 1
  result.add(Node(
    kind: reSkip,
    cp: "#".toRune,
    next: states))

type
  Zclosure = seq[int16]
  TeClosure = seq[(int16, Zclosure)]

func isTransitionZ(n: Node): bool {.inline.} =
  result = case n.kind
    of groupKind:
      n.isCapturing
    of assertionKind:
      true
    else:
      false

func teClosure(
  result: var TeClosure,
  nfa: Nfa,
  state: int16,
  visited: var set[int16],
  zTransitions: Zclosure
) =
  if state in visited:
    return
  visited.incl(state)
  var zTransitionsCurr = zTransitions
  if isTransitionZ(nfa[state]):
    zTransitionsCurr.add(state)
  if nfa[state].kind in matchableKind + {reEOE}:
    result.add((state, zTransitionsCurr))
    return
  for s in nfa[state].next:
    teClosure(result, nfa, s, visited, zTransitionsCurr)

func teClosure(
  result: var TeClosure,
  nfa: Nfa,
  state: int16
) =
  var visited: set[int16]
  var zclosure: Zclosure
  for s in nfa[state].next:
    teClosure(result, nfa, s, visited, zclosure)

type
  TransitionsAll* = seq[seq[int16]]
  ZclosureStates* = seq[seq[Node]]
  Transitions* = object
    allZ*: TransitionsAll
    z*: ZclosureStates

func eRemoval(
  eNfa: Nfa,
  transitions: var Transitions
): Nfa {.raises: [].} =
  ## Remove e-transitions and return
  ## remaining state transtions and
  ## submatches, and zero matches.
  ## Transitions are added in matching order (BFS),
  ## which may help matching performance
  #echo eNfa
  var eNfa = eNfa
  transitions.allZ.setLen(eNfa.len)
  var statesMap = newSeq[int16](eNfa.len)
  for i in 0 .. statesMap.len-1:
    statesMap[i] = -1
  var statePos = 0'i16
  let start = int16(eNfa.len-1)
  statesMap[start] = statePos
  inc statePos
  var closure: TeClosure
  var zc: seq[Node]
  var qw = initDeque[int16](2)
  qw.addFirst(start)
  var qu: set[int16]
  qu.incl(start)
  var qa: int16
  while qw.len > 0:
    try:
      qa = qw.popLast()
    except IndexError:
      doAssert false
    closure.setLen(0)
    teClosure(closure, eNfa, qa)
    eNfa[qa].next.setLen(0)
    for qb, zclosure in closure.items:
      eNfa[qa].next.add(qb)
      if statesMap[qb] == -1:
        statesMap[qb] = statePos
        inc statePos
      assert statesMap[qa] > -1
      assert statesMap[qb] > -1
      transitions.allZ[statesMap[qa]].add(-1'i16)
      zc.setLen(0)
      for z in zclosure:
        zc.add(eNfa[z])
      if zc.len > 0:
        transitions.z.add(zc)
        transitions.allZ[statesMap[qa]][^1] = int16(transitions.z.len-1)
      if qb notin qu:
        qu.incl(qb)
        qw.addFirst(qb)
  transitions.allZ.setLen(statePos)
  result = newSeq[Node](statePos)
  for en, nn in statesMap.pairs:
    if nn == -1:
      continue
    result[nn] = eNfa[en]
    result[nn].next.setLen(0)
    for en2 in eNfa[en].next:
      doAssert statesMap[en2] > -1
      result[nn].next.add(statesMap[en2])

# XXX rename to nfa when Nim v0.19 is dropped
func nfa2*(
  exp: seq[Node],
  transitions: var Transitions
): Nfa {.raises: [RegexError].} =
  result = exp.eNfa.eRemoval(transitions)