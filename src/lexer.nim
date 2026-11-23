import diag
import span
import std/options
import std/strutils

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
  # Stops before }
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

  # FStringPart
  # tokens*: seq[Token]
  # spec*: seq[FStringPart]
  # specSpan*: Span

  if lexer.peek() == '}':
    lexer.pos += 1
    return FStringPart(kind: fsExpr, tokens: subLexer.tokens, spec: @[])
  if lexer.peek() == ':':
    # this is for parsing something like {x:.{p}}
    # lexer.pos += 1
    # let specStart = lexer.pos
    # var depth = 0
    # while true:
    #   if lexer.pos >= lexer.file.content.len:
    #     lexer.fail(
    #       startPos, lexer.file.content.len, "unclosed expression format inside string"
    #     )
    #   if depth == 0 and lexer.peek() == '}':
    #     break
    #   if lexer.peek() == '{':
    #     depth += 1
    #   elif lexer.peek() == '}':
    #     depth -= 1
    #   lexer.pos += 1

    # spec loop: collect the chars until we hit {
    lexer.pos += 1
    let specStart = lexer.pos
    var specStop: int
    var specStr = ""
    var subExpr: FStringPart
    var spec: seq[FStringPart] = @[]

    while true:
      let c = lexer.peek()

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
  # var expr: seq[Token] = @[]
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

    if c == '{':
      lexer.bracketStack.add(tkLBrace)
    elif c == '(':
      lexer.bracketStack.add(tkLParen)
    elif c == '[':
      lexer.bracketStack.add(tkLBracket)
    elif c == '.' and lexer.peek(1) == '[':
      lexer.bracketStack.add(tkDotBracket)
    elif c in ['}', ']', ')'] and lexer.bracketStack.len > 0:
      discard lexer.bracketStack.pop()

    # TODO: real tokens!

proc scan*(file: SherFile, sink: DiagnosticSink): LexerResult =
  var lexer =
    Lexer(file: file, sink: sink, pos: 0, prevTokenKind: tkNL, hasLineBreak: false)

  lexer.scanTokens(inFString = false)
  return LexerResult(tokens: lexer.tokens, pragmas: lexer.pragmas, tests: lexer.tests)
