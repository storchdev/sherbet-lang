import diag
import span

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

type LexerResult* = ref object
  tokens*: seq[Token]
  pragmas*: seq[Span]
  tests*: seq[TestBlock]
