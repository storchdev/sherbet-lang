import diag
import span
import std/strutils
import std/tables
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
    tkEqual
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
    tkBitAnd
    tkBitOr
    tkBitXor
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
    tkBitAndEq
    tkBitOrEq
    tkBitXorEq
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

const LBracketMap = {
  '{': tkLBrace, '(': tkLParen, '[': tkLBracket # ".[": tkDotBracket,
}.toTable
const RBracketMap = {
  '}': tkRBrace, ')': tkRParen, ']': tkRBracket # ".[": tkDotBracket,
}.toTable

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

    var bracketKind = LBracketMap.getOrDefault(c, tkID)
    if bracketKind != tkID:
      lexer.pos += 1
      lexer.bracketStack.add(bracketKind)
      lexer.emitToken(Token(kind: bracketKind), start)
      continue

    bracketKind = RBracketMap.getOrDefault(c, tkID)
    if bracketKind != tkID:
      lexer.pos += 1
      lexer.emitToken(Token(kind: bracketKind), start)
      if lexer.bracketStack.len == 0:
        lexer.fail(start, lexer.pos, &"unmatched {c}")
      discard lexer.bracketStack.pop()
      continue

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

    # Punctuation and operators
    if c == '*':
      let c1 = lexer.peek(1)
      if c1 == '*':
        if lexer.peek(2) == '=':
          lexer.pos += 3
          lexer.emitToken(Token(kind: tkPowerEq), start)
          continue
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkPower), start)
        continue
      if c1 == '=':
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkMulEq), start)
        continue
      lexer.pos += 1
      lexer.emitToken(Token(kind: tkMul), start)
      continue
    if c == '<':
      let c1 = lexer.peek(1)
      if c1 == '<':
        if lexer.peek(2) == '=':
          lexer.pos += 3
          lexer.emitToken(Token(kind: tkLShiftEq), start)
          continue
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkLShift), start)
        continue
      if c1 == '=':
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkLeq), start)
        continue
      lexer.pos += 1
      lexer.emitToken(Token(kind: tkLt), start)
      continue
    if c == '>':
      let c1 = lexer.peek(1)
      if c1 == '>':
        if lexer.peek(2) == '=':
          lexer.pos += 3
          lexer.emitToken(Token(kind: tkRShiftEq), start)
          continue
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkRShift), start)
        continue
      if c1 == '=':
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkGeq), start)
        continue
      lexer.pos += 1
      lexer.emitToken(Token(kind: tkGt), start)
      continue
    if c == '.':
      let c1 = lexer.peek(1)
      if c1 == '.':
        if lexer.peek(2) == '=':
          lexer.pos += 3
          lexer.emitToken(Token(kind: tkRangeEq), start)
          continue
        lexer.pos += 2
        lexer.emitToken(Token(kind: tkRange), start)
        continue
      if c1 == '[':
        lexer.pos += 2
        lexer.bracketStack.add(tkDotBracket)
        lexer.emitToken(Token(kind: tkDotBracket), start)
        continue
      lexer.pos += 1
      lexer.emitToken(Token(kind: tkDot), start)
      continue

    # TODO:other tokens!

    # escape hatch so it doesnt infinite loop on unsupported shit
    lexer.fail(lexer.pos, lexer.pos + 1, "unsupported token start character")

proc scan*(file: SherFile, sink: DiagnosticSink): LexerResult =
  var lexer =
    Lexer(file: file, sink: sink, pos: 0, prevTokenKind: tkNL, hasLineBreak: false)

  try:
    lexer.scanTokens(inFString = false)
  except LexAbort:
    discard # fail gracefully, sink already has errors 

  lexer.pos = file.content.len
  lexer.emitToken(Token(kind: tkEOF), start = file.content.len)
  return LexerResult(tokens: lexer.tokens, pragmas: lexer.pragmas, tests: lexer.tests)
