import diag
import span
import std/strutils
import std/strformat

type
  TokenKind* = enum
    # Data
    tkID
    tkByte
    tkInt
    tkFloat
    tkString
    tkFString
    tkDollar
    tkEOF
    # Whitespace
    tkNL
    # Keywords
    tkFn
    tkLet
    tkIf
    tkElse
    tkWhile
    tkFor
    tkIn
    tkBreak
    tkContinue
    tkReturn
    tkMatch
    tkTry
    tkCatch
    tkRaise
    tkImport
    tkAs
    tkRecord
    tkType
    tkExtern
    tkMemo
    tkAnd
    tkOr
    tkNot
    tkIs
    tkNull
    tkTrue
    tkFalse
    # Operators (numerical)
    tkPlus
    tkMinus
    tkMul
    tkDiv
    tkFloorDiv
    tkPower
    tkEq
    tkNeq
    tkGt
    tkGeq
    tkLt
    tkLeq
    tkMod
    tkAt
    tkBackslash
    # Operators (bit)
    tkTilde
    tkAmp
    tkPipe
    tkCaret
    tkLShift
    tkRShift
    # Brackets
    tkLParen
    tkRParen
    tkLBracket
    tkRBracket
    tkDotBracket
    tkLBrace
    tkRBrace
    # Other symbols
    tkAssign
    tkArrow
    tkFatArrow
    tkRange
    tkRangeEq
    tkDot
    tkComma
    tkColon
    tkSemicolon
    tkBang
    tkQuestion
    tkQuestionDot
    # Operate + assign
    tkPlusEq
    tkMinusEq
    tkMulEq
    tkDivEq
    tkFloorDivEq
    tkModEq
    tkPowerEq
    tkAtEq
    tkAmpEq
    tkPipeEq
    tkCaretEq
    tkLShiftEq
    tkRShiftEq

  Token* = object
    hasLineBreakBefore*: bool
    span*: Span
    case kind*: TokenKind
    of tkInt, tkFloat, tkString, tkID: text*: string
    of tkDollar: argIndex*: int
    of tkByte: byteVal*: uint8
    of tkFString: parts*: seq[FStringPart]
    else:
      discard

  FStringPartKind* = enum
    fsText
    fsExpr

  FStringPart* = object
    case kind*: FStringPartKind
    of fsText: text*: string
    of fsExpr:
      tokens*: seq[Token]
      spec*: seq[FStringPart]
      specSpan*: Span

type TestBlockKind* = enum
  testIn
  testOut

type TestBlock* = ref object
  kind*: TestBlockKind
  span*: Span
  path*: string

type Lexer = ref object
  tokens*: seq[Token]
  pragmas*: seq[Span]
  tests*: seq[TestBlock]
  bracketStack*: seq[TokenKind]
  file*: SherFile
  sink*: DiagnosticSink
  pos*: int
  prevTokenKind*: TokenKind
  hasLineBreak*: bool
  stringStartPos*: int # must be set when scanTokens(inFString=true)

type LexerResult* = ref object
  tokens*: seq[Token]
  pragmas*: seq[Span]
  tests*: seq[TestBlock]

type LexAbort = object of CatchableError

proc peek(lexer: Lexer, n: int = 0): char =
  if lexer.pos + n >= lexer.file.content.len:
    return '\0'

  return lexer.file.content[lexer.pos + n]

proc fail(lexer: Lexer, start: int, stop: int, message: string) {.noreturn.} =
  lexer.sink.reportError(
    initSpan(lexer.file.index, start, min(stop, lexer.file.content.len)),
    message,
    @[],
    @[],
  )
  raise newException(LexAbort, "")

proc emitToken(lexer: Lexer, token: Token, start: int) =
  var tcopy = token
  tcopy.span = initSpan(lexer.file.index, start, lexer.pos)
  tcopy.hasLineBreakBefore = lexer.hasLineBreak
  lexer.tokens.add(tcopy)
  lexer.prevTokenKind = tcopy.kind
  lexer.hasLineBreak = false

proc scanTokens(lexer: Lexer, inFString: bool)

proc scanFStringExpr(mainLexer: Lexer, stringStartPos: int): FStringPart =
  # Starts at {
  # Stops after }
  # Returns a FStringPart with kind fsExpr

  let lexer = mainLexer
  let subLexer = Lexer(
    file: lexer.file,
    sink: lexer.sink,
    pos: lexer.pos + 1, # consume the {
    prevTokenKind: tkNL,
    hasLineBreak: false,
    stringStartPos: stringStartPos,
  )
  subLexer.scanTokens(inFString = true)
  # TODO: {x=} form
  lexer.pos = subLexer.pos # update so we are about to consume } or :

  if lexer.peek() == '}':
    lexer.pos += 1
    return FStringPart(kind: fsExpr, tokens: subLexer.tokens, spec: @[])
  if lexer.peek() == ':':
    # spec loop: collect the chars until we hit {
    lexer.pos += 1
    let specStart = lexer.pos
    var specStop: int
    var specStr = ""
    var subExpr: FStringPart
    var spec: seq[FStringPart] = @[]

    while true:
      if lexer.pos >= lexer.file.content.len:
        lexer.fail(stringStartPos, lexer.pos, "unclosed string format")

      let c = lexer.peek()

      if c in ['\n', '"']:
        lexer.fail(
          stringStartPos, lexer.pos, "unexpected newline or quote in string format"
        )

      if c == '{':
        if specStr.len > 0:
          spec.add(FStringPart(kind: fsText, text: specStr))
          specStr = ""
        subExpr = scanFStringExpr(lexer, stringStartPos)
        spec.add(subExpr)
        continue

      if c == '}':
        # spec ends here
        if specStr.len > 0:
          spec.add(FStringPart(kind: fsText, text: specStr))
          specStr = ""
        specStop = lexer.pos # at the }
        lexer.pos += 1
        break

      specStr.add(c)
      lexer.pos += 1

    return FStringPart(
      kind: fsExpr,
      tokens: subLexer.tokens,
      spec: spec,
      specSpan: initSpan(lexer.file.index, specStart, specStop),
    )

  lexer.fail(stringStartPos, lexer.pos, "unclosed expression inside string")

proc scanString(lexer: Lexer) =
  # TODO: raw strings, dropping first newline and common indents in multiline
  let startPos = lexer.pos

  var multi: bool
  if lexer.peek(1) == '"' and lexer.peek(2) == '"':
    lexer.pos += 3
    multi = true
  else:
    lexer.pos += 1
    multi = false

  # invariant: if a fsText part is added to parts, the original str must be cleared
  var str = ""
  var parts: seq[FStringPart] = @[]
  var done = false

  while true:
    if lexer.pos >= lexer.file.content.len:
      lexer.fail(startPos, lexer.file.content.len, "unclosed string")

    if (lexer.peek() == '"' and not multi):
      done = true
      lexer.pos += 1
    if (lexer.peek(), lexer.peek(1), lexer.peek(2)) == ('"', '"', '"') and multi:
      done = true
      lexer.pos += 3

    if done:
      if str.len > 0:
        parts.add(FStringPart(kind: fsText, text: str))
        str = ""
      break

    if (lexer.peek(), lexer.peek(1)) == ('{', '{'):
      str.add('{')
      lexer.pos += 2
      continue

    if (lexer.peek(), lexer.peek(1)) == ('}', '}'):
      str.add('}')
      lexer.pos += 2
      continue

    if lexer.peek() == '}':
      lexer.fail(startPos, lexer.pos + 1, "unexpected '}' in string")

    if lexer.peek() == '\\':
      # always consume char after
      let c = lexer.peek(1)
      var esc: char

      case c
      of 'n':
        esc = '\n'
        lexer.pos += 2
      of 't':
        esc = '\t'
        lexer.pos += 2
      of 'r':
        esc = '\r'
        lexer.pos += 2
      of '0':
        esc = char(0)
        lexer.pos += 2
      of '\\':
        esc = '\\'
        lexer.pos += 2
      of '"':
        esc = '"'
        lexer.pos += 2
      of '\'':
        esc = '\''
        lexer.pos += 2
      of 'x':
        if lexer.peek(2) notin HexDigits or lexer.peek(3) notin HexDigits:
          lexer.fail(startPos, lexer.pos + 4, "invalid hex escape")
        esc = char(parseHexInt(lexer.file.content[lexer.pos + 2 .. lexer.pos + 3]))
        lexer.pos += 4
      else:
        lexer.fail(startPos, lexer.pos + 2, "invalid escape sequence")

      str.add(esc)
      continue

    if lexer.peek() == '{':
      if str.len > 0:
        parts.add(FStringPart(kind: fsText, text: str))
        str = ""

      let part = scanFStringExpr(lexer, startPos)
      parts.add(part)
      continue

    if lexer.peek() == '\n' and not multi:
      lexer.fail(startPos, lexer.pos, "unclosed string")

    # ordinary characters
    str.add(lexer.file.content[lexer.pos])
    lexer.pos += 1

  if parts.len == 0: # empty str
    lexer.emitToken(Token(kind: tkString, text: ""), startPos)
  elif parts.len == 1 and parts[0].kind == fsText: # non f string
    lexer.emitToken(Token(kind: tkString, text: parts[0].text), startPos)
  else: # f string
    lexer.emitToken(Token(kind: tkFString, parts: parts), startPos)

proc getKeywordKind(word: string): TokenKind =
  return
    case word
    of "fn": tkFn
    of "let": tkLet
    of "if": tkIf
    of "else": tkElse
    of "while": tkWhile
    of "for": tkFor
    of "in": tkIn
    of "break": tkBreak
    of "continue": tkContinue
    of "return": tkReturn
    of "match": tkMatch
    of "try": tkTry
    of "catch": tkCatch
    of "raise": tkRaise
    of "import": tkImport
    of "as": tkAs
    of "record": tkRecord
    of "type": tkType
    of "extern": tkExtern
    of "memo": tkMemo
    of "and": tkAnd
    of "or": tkOr
    of "not": tkNot
    of "is": tkIs
    of "null": tkNull
    of "true": tkTrue
    of "false": tkFalse
    else: tkID

const LBrackets = {tkLBrace, tkLParen, tkLBracket, tkDotBracket}
const RBrackets = {tkRBrace, tkRParen, tkRBracket}
const BinaryOpTokens = {
  tkPlus, tkMinus, tkMul, tkDiv, tkFloorDiv, tkPower, tkEq, tkNeq, tkGt, tkGeq, tkLt,
  tkLeq, tkMod, tkAt, tkBackslash, tkAmp, tkPipe, tkCaret, tkLShift, tkRShift, tkRange,
  tkRangeEq, tkDot, tkQuestionDot, tkPlusEq, tkMinusEq, tkMulEq, tkDivEq, tkFloorDivEq,
  tkModEq, tkPowerEq, tkAtEq, tkAmpEq, tkPipeEq, tkCaretEq, tkLShiftEq, tkRShiftEq,
  tkAnd, tkOr, tkIn, tkIs,
}
# It makes sense to continue when a newline appears after these
const BeforeNLTokens =
  BinaryOpTokens - {tkRange, tkRangeEq} +
  {tkAssign, tkFatArrow, tkColon, tkComma, tkNL, tkNot} + LBrackets

# These drop the previous newline
const AfterNLTokens = {tkDot, tkDotBracket, tkQuestionDot, tkPipe, tkCatch, tkElse}

const TokenSpellings = [
  ("**=", tkPowerEq),
  ("~/=", tkFloorDivEq),
  ("<<=", tkLShiftEq),
  (">>=", tkRShiftEq),
  ("..=", tkRangeEq),
  ("~/", tkFloorDiv),
  ("**", tkPower),
  ("<<", tkLShift),
  (">>", tkRShift),
  ("..", tkRange),
  ("==", tkEq),
  ("!=", tkNeq),
  ("<=", tkLeq),
  (">=", tkGeq),
  ("->", tkArrow),
  ("=>", tkFatArrow),
  ("?.", tkQuestionDot),
  (".[", tkDotBracket),
  ("+=", tkPlusEq),
  ("-=", tkMinusEq),
  ("*=", tkMulEq),
  ("/=", tkDivEq),
  ("%=", tkModEq),
  ("@=", tkAtEq),
  ("&=", tkAmpEq),
  ("|=", tkPipeEq),
  ("^=", tkCaretEq),
  ("+", tkPlus),
  ("-", tkMinus),
  ("*", tkMul),
  ("/", tkDiv),
  ("~", tkTilde),
  ("%", tkMod),
  ("@", tkAt),
  (r"\", tkBackslash),
  ("&", tkAmp),
  ("|", tkPipe),
  ("^", tkCaret),
  ("!", tkBang),
  ("<", tkLt),
  (">", tkGt),
  (".", tkDot),
  ("=", tkAssign),
  ("?", tkQuestion),
  ("(", tkLParen),
  ("[", tkLBracket),
  ("{", tkLBrace),
  (")", tkRParen),
  ("]", tkRBracket),
  ("}", tkRBrace),
  (",", tkComma),
  (":", tkColon),
  (";", tkSemicolon),
]

proc scanTokens(lexer: Lexer, inFString: bool) =
  while true:
    if lexer.pos >= lexer.file.content.len:
      return

    let c = lexer.peek()
    if c == ' ' or c == '\t':
      lexer.pos += 1
      continue

    if c == '"':
      lexer.scanString()
      continue

    if c in ['}', ':'] and inFString and lexer.bracketStack.len == 0:
      return

    let start = lexer.pos

    # Names and keywords
    if c in IdentStartChars:
      lexer.pos += 1
      while true:
        let c1 = lexer.peek()
        if c1 notin IdentChars:
          break
        lexer.pos += 1

      let lexeme = lexer.file.content[start ..< lexer.pos]
      let kind = getKeywordKind(lexeme)
      if kind == tkID:
        lexer.emitToken(Token(kind: tkID, text: lexeme), start)
      else:
        lexer.emitToken(Token(kind: kind), start)
      continue

    if c == '\n':
      if inFString:
        # TODO: revisit when multiline str
        lexer.fail(
          lexer.stringStartPos, lexer.pos, "unexpected line break in string expression"
        )
      lexer.pos += 1
      # emit if both are true:
      # no innermost bracket OR innermost bracket is a {
      # prev token is not a continuation (allowed before a NL)
      if (lexer.bracketStack.len == 0 or lexer.bracketStack[^1] == tkLBrace) and
          lexer.prevTokenKind notin BeforeNLTokens:
        lexer.emitToken(Token(kind: tkNL), start)

      lexer.hasLineBreak = true
      continue

    # match comments now so it doesnt get picked up by `/` later
    if c == '/' and lexer.peek(1) == '/':
      lexer.pos += 2
      while lexer.peek() != '\n' and lexer.pos < lexer.file.content.len:
        lexer.pos += 1
      continue

    var match = false
    for str, tk in TokenSpellings.items:
      if strutils.continuesWith(lexer.file.content, str, lexer.pos):
        # must be the longest one

        lexer.pos += str.len

        # handle bracket stack
        if tk in LBrackets:
          lexer.bracketStack.add(tk)
        elif tk in RBrackets:
          if lexer.bracketStack.len == 0:
            lexer.fail(start, lexer.pos, &"unmatched {c}")
          discard lexer.bracketStack.pop()

        lexer.emitToken(Token(kind: tk), start)
        match = true
        break

    if match:
      continue

    # TODO:other tokens!

    # escape hatch so it doesnt infinite loop on unsupported shit
    lexer.fail(lexer.pos, lexer.pos + 1, "unsupported token start character")

proc dropPrevNLTokens(lexer: Lexer) =
  var newTokens: seq[Token] = @[]
  for i, t in lexer.tokens:
    if t.kind == tkNL and i < lexer.tokens.len - 1:
      if lexer.tokens[i + 1].kind in AfterNLTokens:
        continue
    newTokens.add(t)
  lexer.tokens = newTokens

proc scan*(file: SherFile, sink: DiagnosticSink): LexerResult =
  var lexer =
    Lexer(file: file, sink: sink, pos: 0, prevTokenKind: tkNL, hasLineBreak: false)

  try:
    lexer.scanTokens(inFString = false)
  except LexAbort:
    discard # fail gracefully, sink already has errors 

  lexer.pos = file.content.len
  lexer.emitToken(Token(kind: tkEOF), start = file.content.len)

  # Hybrid approach: we already "drop" NLs that follow tokens in the main loop
  # because it doesn't require lookahead
  lexer.dropPrevNLTokens()

  return LexerResult(tokens: lexer.tokens, pragmas: lexer.pragmas, tests: lexer.tests)
