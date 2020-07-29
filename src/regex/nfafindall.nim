## Linear time NFA findAll

#[
The nfamatch find algorithm can be used
to search all matches within a string,
however doing this may take quadratic time
in some cases. Ex: findAll("aaaa", re"\w+\d|\w")
this will call find 4 times and consume the
entire string every time.

The way to avoid this is to store all possible
matches until we know whether they are valid
and should be returned or they must be replaced by an overlapping
match taking priority according to PCRE rules
(longest-left match wins).

This algorithm works the same way as calling
nfamatch find repeatedly would, except it keeps
all possible matches and returns them as soon
as the current character cannot match the regex,
i.e: it's a safe point to return. This is just
to avoid consuming too much memory if possible.

The downside is it takes linear time in the length
of the text to match + the regex. In most cases it
should take less space, since the matches are index ranges.

The tricky part is to replace all overlapped
temporary matches every time an Eoe is found,
then prune the next states (as they're overlapped),
then try to match the initial state to the
current character (next possible match). Other than
that is the same algorithm as nfamatch.
]#

import unicode
import tables

import nodematch
import nodetype
import nfatype

func bwRuneAt(s: string, n: int): Rune =
  ## Take rune ending at ``n``
  doAssert n >= 0
  doAssert n <= s.len-1
  var n = n
  while n > 0 and s[n].ord shr 6 == 0b10:
    dec n
  fastRuneAt(s, n, result, false)

type
  MatchItemIdx = int
  MatchItem = tuple
    capt: CaptIdx
    bounds: Bounds
  Matches = seq[MatchItem]
  RegexMatches* = object
    a, b: Submatches
    m: Matches
    c: Capts

# XXX make it log(n)? altough this does
#     not add to the time complexity
func add(ms: var Matches, m: MatchItem) {.inline.} =
  ## Add `m` to `ms`. Remove all overlapped matches.
  var size = 0
  for i in countdown(ms.len-1, 0):
    if max(ms[i].bounds.b, ms[i].bounds.a) < m.bounds.a:
      size = i+1
      break
  ms.setLen size
  system.add(ms, m)

func clear(ms: var Matches) {.inline.} =
  ms.setLen 0

template initMaybeImpl(
  ms: var RegexMatches,
  regex: Regex
) =
  if ms.a == nil:
    assert ms.b == nil
    ms.a = newSubmatches(regex.nfa.len)
    ms.b = newSubmatches(regex.nfa.len)
  doAssert ms.a.cap == regex.nfa.len and
    ms.b.cap == regex.nfa.len

func hasMatches(ms: RegexMatches): bool {.inline.} =
  return ms.m.len > 0

func clear(ms: var RegexMatches) {.inline.} =
  ms.a.clear()
  ms.b.clear()
  ms.m.clear()
  ms.c.setLen 0

iterator bounds*(ms: RegexMatches): Slice[int] {.inline.} =
  for i in 0 .. ms.m.len-1:
    yield ms.m[i].bounds

iterator items*(ms: RegexMatches): MatchItemIdx {.inline.} =
  for i in 0 .. ms.m.len-1:
    yield i

func fillMatchImpl*(
  m: var RegexMatch,
  mi: MatchItemIdx,
  ms: RegexMatches,
  regex: Regex
) {.inline.} =
  if m.namedGroups.len != regex.namedGroups.len:
    m.namedGroups = regex.namedGroups
  constructSubmatches(
    m.captures, ms.c, ms.m[mi].capt, regex.groupsCount)
  m.boundaries = ms.m[mi].bounds

func dummyMatch*(ms: var RegexMatches, i: int) {.inline.} =
  ## hack to support `split` last value.
  ## we need to add the end boundary if
  ## it has not matched the end
  ## (no match implies this too)
  template ab: untyped = ms.m[^1].bounds
  if ms.m.len == 0 or max(ab.a, ab.b) < i:
    ms.m.add (-1'i32, i+1 .. i)

func submatch(
  ms: var RegexMatches,
  regex: Regex,
  i: int,
  cPrev, c: int32
) {.inline.} =
  template tns: untyped = regex.transitions
  template nfa: untyped = regex.nfa
  template smA: untyped = ms.a
  template smB: untyped = ms.b
  template capts: untyped = ms.c
  template n: untyped = ms.a[smi].ni
  template capt: untyped = ms.a[smi].ci
  template bounds: untyped = ms.a[smi].bounds
  smB.clear()
  var captx: int32
  var matched = true
  var eoeFound = false
  var smi = 0
  while smi < smA.len:
    for nti, nt in nfa[n].next.pairs:
      if smB.hasState nt:
        continue
      if nfa[nt].kind != reEoe and not match(nfa[nt], c.Rune):
        continue
      matched = true
      captx = capt
      if tns.allZ[n][nti] > -1:
        for z in tns.z[tns.allZ[n][nti]]:
          if not matched:
            break
          case z.kind
          of groupKind:
            capts.add CaptNode(
              parent: captx,
              bound: i,
              idx: z.idx)
            captx = (capts.len-1).int32
          of assertionKind:
            matched = match(z, cPrev.Rune, c.Rune)
          else:
            assert false
            discard
      if matched:
        if nfa[nt].kind == reEoe:
          #debugEcho "eoe ", bounds, " ", ms.m
          ms.m.add (captx, bounds.a .. i-1)
          smA.clear()
          if not eoeFound:
            eoeFound = true
            smA.add (0'i16, -1'i32, i .. i-1)
          smi = -1
          break
        smB.add (nt, captx, bounds.a .. i-1)
    inc smi
  swap smA, smB

func findSomeImpl*(
  text: string,
  regex: Regex,
  ms: var RegexMatches,
  start = 0
): int =
  template smA: untyped = ms.a
  initMaybeImpl(ms, regex)
  ms.clear()
  var
    c = Rune(-1)
    cPrev = -1'i32
    i = start
    iPrev = start
  smA.add (0'i16, -1'i32, start .. start-1)
  if 0 <= start-1 and start-1 <= len(text)-1:
    cPrev = bwRuneAt(text, start-1).int32
  while i < len(text):
    #debugEcho "it= ", i, " ", cPrev
    fastRuneAt(text, i, c, true)
    submatch(ms, regex, iPrev, cPrev, c.int32)
    when true:  # early return
      if smA.len == 0:
        #debugEcho "smA 0"
        if ms.hasMatches() and i < len(text):
          #debugEcho "m= ", ms.m.s
          #debugEcho "sma=0=", i
          return i
    smA.add (0'i16, -1'i32, i .. i-1)
    iPrev = i
    cPrev = c.int32
  submatch(ms, regex, iPrev, cPrev, -1'i32)
  doAssert smA.len == 0
  if ms.hasMatches():
    #debugEcho "m= ", ms.m.s
    return i
  #debugEcho "noMatch"
  return -1