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
  bracketStack*: seq[Token]
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

proc scanString(lexer: Lexer) =
  let startPos = lexer.pos

  var multi: bool
  if lexer.peek(1) == '"' and lexer.peek(2) == '"':
    lexer.pos += 2
    multi = true
  else:
    multi = false

  # invariant: if a part is added to parts, the original (str or expr) must be cleared
  var str: seq[char] = @[]
  var expr: seq[Token] = @[]
  var parts: seq[FStringPart] = @[]

  while true:
    if lexer.pos >= len(lexer.file.content):
      lexer.fail(startPos, len(lexer.file.content) - 1, "unclosed string")

    if (lexer.peek() == '"' and not multi) or
        (lexer.peek(), lexer.peek(1), lexer.peek(2)) == ('"', '"', '"') and multi:
      if len(str) > 0:
        parts.add(FStringPart(kind: fsText, text: str.join()))
        str = @[]
      elif len(expr) > 0:
        parts.add(FStringPart(kind: fsExpr, tokens: expr))
        parts = @[]
      else:
        # we have empty string
        parts.add(FStringPart(kind: fsText, text: ""))
      break

    if (lexer.peek(), lexer.peek(1)) == ('{', '{'):
      str.add('{')
      lexer.pos += 1
      continue

    if (lexer.peek(), lexer.peek(1)) == ('}', '}'):
      str.add('}')
      lexer.pos += 1
      continue

    # TODO handle escapes
    # TODO handle exprs

  # TODO
  if len(parts) == 1 and parts[0].kind == fsText:
    # add Token with kind=tkString and text=parts[0].text
    discard
  else:
    discard

proc scan*(file: SherFile, sink: DiagnosticSink): LexerResult =
  var lexer = Lexer(
    tokens: @[],
    bracketStack: @[],
    file: file,
    sink: sink,
    pos: 0,
    prevToken: none(Token),
    lineBreak: false,
  )
  while true:
    let c = lexer.peek(0)
    if c == ' ' or c == '\t':
      lexer.pos += 1
      continue

    if c == '"':
      lexer.scanString()

  # TODO
