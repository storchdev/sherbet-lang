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
    of fsExpr: tokens*: seq[Token]

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
  prevToken*: Option[Token]
  lineBreak*: bool

type LexerResult* = ref object
  tokens*: seq[Token]
  pragmas*: seq[Span]
  tests*: seq[TestBlock]

type LexAbort = object of CatchableError

proc peek*(lexer: Lexer, n: int = 0): char =
  if lexer.pos + n >= len(lexer.file.content):
    return '\0'

  return lexer.file.content[lexer.pos + n]

proc fail(lexer: Lexer, start: int, stop: int, message: string) =
  lexer.sink.reportError(initSpan(lexer.file.index, start, stop), message, @[], @[])
  raise newException(LexAbort, "")

proc scanTokens(lexer: Lexer, inFString: bool)

proc scanString(lexer: Lexer) =
  let startPos = lexer.pos

  var multi: bool
  if lexer.peek(1) == '"' and lexer.peek(2) == '"':
    lexer.pos += 2
    multi = true
  else:
    multi = false

  # invariant: if a fsText part is added to parts, the original str must be cleared
  var str: seq[char] = @[]
  # var expr: seq[Token] = @[]
  var parts: seq[FStringPart] = @[]

  while true:
    if lexer.pos >= len(lexer.file.content):
      lexer.fail(startPos, len(lexer.file.content) - 1, "unclosed string")

    if (lexer.peek() == '"' and not multi) or
        (lexer.peek(), lexer.peek(1), lexer.peek(2)) == ('"', '"', '"') and multi:
      if len(str) > 0:
        parts.add(FStringPart(kind: fsText, text: str.join()))
        str = @[]
      # elif len(expr) > 0:
      #   parts.add(FStringPart(kind: fsExpr, tokens: expr))
      #   parts = @[]
      # else:
      # # we have empty string
      # parts.add(FStringPart(kind: fsText, text: ""))
      break

    if (lexer.peek(), lexer.peek(1)) == ('{', '{'):
      str.add('{')
      lexer.pos += 1
      continue

    if (lexer.peek(), lexer.peek(1)) == ('}', '}'):
      str.add('}')
      lexer.pos += 1
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
          lexer.fail(lexer.pos, lexer.pos + 4, "invalid hex escape")
        esc = char(parseHexInt(lexer.file.content[lexer.pos + 2 .. lexer.pos + 3]))
        lexer.pos += 4
      else:
        lexer.fail(lexer.pos, lexer.pos + 2, "invalid escape sequence")

      str.add(esc)
      continue

    if lexer.peek() == '{':
      if len(str) > 0:
        parts.add(FStringPart(kind: fsText, text: str.join()))
        str = @[]

      let subLexer = Lexer(
        file: lexer.file,
        sink: lexer.sink,
        pos: lexer.pos + 1,
        prevToken: none(Token),
        lineBreak: false,
      )
      subLexer.scanTokens(inFString = true)
      parts.add(FStringPart(kind: fsExpr, tokens: subLexer.tokens))

      lexer.pos = subLexer.pos
      continue

  if len(parts) == 0: # empty str
    lexer.tokens.add(Token(kind: tkString, text: ""))
  elif len(parts) == 1 and parts[0].kind == fsText: # non f string
    lexer.tokens.add(Token(kind: tkString, text: parts[0].text))
  else: # f string
    lexer.tokens.add(Token(kind: tkFString, parts: parts))

proc scanTokens(lexer: Lexer, inFString: bool) =
  while true:
    let c = lexer.peek(0)
    if c == ' ' or c == '\t':
      lexer.pos += 1
      continue

    if c == '"':
      lexer.scanString()
      continue

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
    Lexer(file: file, sink: sink, pos: 0, prevToken: none(Token), lineBreak: false)

  lexer.scanTokens(inFString = false)
  return LexerResult(tokens: lexer.tokens, pragmas: lexer.pragmas, tests: lexer.tests)
