module Token
  alias Type = String

  struct Token
    getter type, literal, line, column

    def initialize(@type : Type, @literal : String, @line : Int32 = 0, @column : Int32 = 0)
    end
  end

  KEYWORDS = {
    "fn"     => FUNCTION,
    "let"    => LET,
    "true"   => TRUE,
    "false"  => FALSE,
    "if"     => IF,
    "else"   => ELSE,
    "return" => RETURN,
    "do"     => DO,
  } of String => Token

  def self.lookup_ident(ident : String)
    return KEYWORDS[ident] if KEYWORDS.has_key?(ident)
    return IDENT
  end

  # Meta types
  EMPTY   = Token.new("EMPTY", "EMPTY")
  ILLEGAL = Token.new("ILLEGAL", "ILLEGAL")
  EOF     = Token.new("EOF", Char::ZERO.to_s)

  # Identifiers and literals
  IDENT  = Token.new("IDENT", "ident")
  INT    = Token.new("INT", "int")
  FLOAT  = Token.new("FLOAT", "float")
  STRING = Token.new("STRING", "string")

  # Operators
  ASSIGN   = Token.new("ASSIGN", "=")
  PLUS     = Token.new("PLUS", "+")
  MINUS    = Token.new("MINUS", "-")
  BANG     = Token.new("BANG", "!")
  ASTERISK = Token.new("ASTERISK", "*")
  SLASH    = Token.new("SLASH", "/")
  LT       = Token.new("LT", "<")
  GT       = Token.new("GT", ">")

  # Comparators
  EQ     = Token.new("EQ", "==")
  NOT_EQ = Token.new("NOT_EQ", "!=")

  # Delimiters
  COMMA     = Token.new("COMMA", ",")
  SEMICOLON = Token.new("SEMICOLON", ";")
  LPAREN    = Token.new("LPAREN", "(")
  RPAREN    = Token.new("RPAREN", ")")
  LBRACE    = Token.new("LBRACE", "{")
  RBRACE    = Token.new("RBRACE", "}")
  LBRACKET  = Token.new("LBRACKET", "[")
  RBRACKET  = Token.new("RBRACKET", "]")

  # Keywords
  FUNCTION = Token.new("FUNCTION", "fn")
  DO       = Token.new("DO", "do")
  LET      = Token.new("LET", "let")
  TRUE     = Token.new("TRUE", "true")
  FALSE    = Token.new("FALSE", "false")
  IF       = Token.new("IF", "if")
  ELSE     = Token.new("ELSE", "else")
  RETURN   = Token.new("RETURN", "return")
end
