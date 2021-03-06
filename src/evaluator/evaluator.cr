require "debug"

require "../ast"
require "../object/*"
require "./builtins"

module Evaluator
  class Evaluator
    property program : AST::Program
    property env : PheltObject::Environment

    @current_token : Token::Token = Token::EMPTY
    @current_block : Array(AST::Statement)

    NULL  = PheltObject::Null.new
    TRUE  = PheltObject::Boolean.new(true)
    FALSE = PheltObject::Boolean.new(false)

    @@stdlib = File.read("./src/phelt/stdlib.ph")

    def initialize(@program, @env = PheltObject::Environment.new)
      load_objects_env
      @current_block = @program.statements
    end

    def load_objects_env
      if @env.external_loaded == false
        parser = Parser::Parser.new(Lexer::Lexer.new(@@stdlib))
        program = parser.parse_program
        if (parser.errors.size > 0)
          parser.errors.each do |error|
            STDERR.puts parser.formatted_error(error)
          end
          exit(1)
        end
        result = eval(program, @env)
        if error?(result)
          debug!(result)
          exit(1)
        end
        @env.external_loaded = true
      end
    end

    def eval
      eval(@program, @env)
    end

    def eval(node : AST::Node, env : PheltObject::Environment) : PheltObject::Object
      case node
      in AST::Program
        return eval_program(node.statements, env)
      in AST::ExpressionStatement
        @current_token = node.token
        return eval(node.expression, env)
      in AST::BlockStatement
        return eval_block_statement(node, env)
      in AST::BreakStatement
        return PheltObject::Break.new
      in AST::IntegerLiteral
        return PheltObject::Integer.new(node.value)
      in AST::FloatLiteral
        return PheltObject::Float.new(node.value)
      in AST::BooleanLiteral
        @current_token = node.token
        return bool_to_boolean(node.value)
      in AST::NullLiteral
        return NULL
      in AST::StringLiteral
        return PheltObject::String.new(node.value)
      in AST::PrefixExpression
        @current_token = node.right.token
        right = eval(node.right, env)
        return right if error?(right)
        return eval_prefix_expression(node, right, env)
      in AST::InfixExpression
        @current_token = node.left.token
        left = eval(node.left, env)
        return left if error?(left)
        @current_token = node.right.token
        right = eval(node.right, env)
        return right if error?(right)
        return eval_infix_expression(node.operator, left, right)
      in AST::AssignmentInfixExpression
        left = node.left
        @current_token = node.right.token
        right = eval(node.right, env)
        return right if error?(right)
        return eval_assignment_infix_expression(node.operator, left, right, env)
      in AST::InDecrementExpression
        left = node.left
        return eval_indecrement_infix_expression(node.operator, left, env)
      in AST::IfExpression
        @current_token = node.condition.token
        return eval_if_expression(node, env)
      in AST::ReturnStatement
        @current_token = node.token
        value = eval(node.return_value, env)
        return value if error?(value)
        return PheltObject::Return.new(value)
      in AST::LetStatement
        @current_token = node.token
        value = eval(node.value, env)
        return value if error?(value)
        return error("Cannot redefine constant #{node.name.value}") if env.constant?(node.name.value)
        env.set(node.name.value, value)
      in AST::ConstStatement
        value = eval(node.value, env)
        return value if error?(value)
        return error("Cannot redefine constant #{node.name.value}") if env.constant?(node.name.value)
        env.set(node.name.value, value, true)
      in AST::Identifier
        return eval_identifier(node, env)
      in AST::FunctionLiteral
        params = node.parameters
        body = node.body
        return PheltObject::Function.new(params, body, env)
      in AST::DoLiteral
        body = node.body
        return eval_do(body, env)
      in AST::CallExpression
        function = eval(node.function, env)
        return function if error?(function)
        args = eval_expressions(node.arguments, env)
        return args[0] if args.size == 1 && error?(args[0])
        return error("Object is not a function") if !function.is_a? PheltObject::Function | PheltObject::Builtin
        return apply_function(function.as(PheltObject::Function | PheltObject::Builtin), args, env)
      in AST::ArrayLiteral
        elements = eval_expressions(node.elements, env)
        return elements[0] if elements.size == 1 && error?(elements[0])
        return PheltObject::Array.new(elements)
      in AST::HashLiteral
        return eval_hash_literal(node, env)
      in AST::IndexExpression
        left = eval(node.left, env)
        return left if error?(left)
        index = eval(node.index, env)
        return index if error?(index)
        return eval_index_expression(left, index)
      in AST::ObjectAccessExpression
        @current_token = node.left.token
        left = eval(node.left, env)
        return left if error?(left)
        index = PheltObject::String.new(node.index.value)
        return eval_object_access_expression(left, index, env)
      in AST::ObjectCallExpression
        @current_token = node.left.token
        left = eval(node.left, env)
        return left if error?(left)
        index = PheltObject::String.new(node.index.value)
        args = eval_expressions(node.arguments, env)
        return args[0] if args.size == 1 && error?(args[0])
        return eval_object_access_expression(left, index, env, args)
      in AST::ForExpression
        return eval_for(node, env)
      in AST::WhileExpression
        return eval_while(node, env)
      in AST::Statement
        return NULL
      in AST::Expression
        return NULL
      end
    end

    def eval(node : Nil)
      return NULL
    end

    def bool_to_boolean(value)
      value ? TRUE : FALSE
    end

    def truthy?(object : PheltObject::Object)
      case object
      when NULL
        return false
      when TRUE
        return true
      when FALSE
        return false
      else
        return true
      end
    end

    def apply_function(function : PheltObject::Function | PheltObject::Builtin, args : Array(PheltObject::Object), env : PheltObject::Environment)
      case function
      when PheltObject::Function
        extended_env = extend_function_env(function, args)
        evaluated = eval(function.body, extended_env)
        return unwrap_return_value(evaluated)
      when PheltObject::Builtin
        value = function.function.call(args, env)
        if value.is_a? PheltObject::Error
          return error("#{value.message}")
        end
        return value
      else
        return error("#{function.type} is not a function")
      end
    end

    def eval_do(body : AST::BlockStatement, env : PheltObject::Environment)
      extended_env = PheltObject::Environment.new(env, scoped = true)
      evaluated = eval(body, extended_env)
      return unwrap_return_value(evaluated)
    end

    def eval_for(node : AST::ForExpression, env : PheltObject::Environment)
      extended_env = PheltObject::Environment.new(env)
      initial = eval(node.initial, extended_env)

      loop do
        condition = eval(node.condition, extended_env)
        if condition == FALSE
          break
        end
        evaluated = eval(node.statement, extended_env)
        return evaluated if error?(evaluated)

        if evaluated.is_a? PheltObject::Break
          break
        end

        final = eval(node.final, extended_env)
        return final if error?(final)
      end

      return NULL
    end

    def eval_while(node : AST::WhileExpression, env : PheltObject::Environment)
      extended_env = PheltObject::Environment.new(env)

      loop do
        condition = eval(node.condition, extended_env)
        if condition == FALSE
          break
        end

        evaluated = eval(node.statement, extended_env)
        return evaluated if error?(evaluated)
        if evaluated.is_a? PheltObject::Break
          break
        end
      end

      return NULL
    end

    def extend_function_env(function : PheltObject::Function, args : Array(PheltObject::Object))
      extended_env = PheltObject::Environment.new(function.env)

      function.parameters.each_with_index do |param, index|
        extended_env.set(param.value, args[index])
      end

      return extended_env
    end

    def unwrap_return_value(object : PheltObject::Object)
      if object.is_a? PheltObject::Return
        return object.value
      end
      return object
    end

    def eval_identifier(node : AST::Identifier, env : PheltObject::Environment)
      if env.exists?(node.value)
        return env.get(node.value)
      else
        if ::Evaluator::BUILTINS.has_key? node.value
          return ::Evaluator::BUILTINS[node.value]
        end
      end
      @current_token = node.token
      return error("Undefined identifier #{node.value}")
    end

    def eval_expressions(expressions : Array(AST::Expression), env : PheltObject::Environment)
      result = [] of PheltObject::Object

      expressions.each do |expression|
        evaluated = eval(expression, env)
        return [evaluated] if error?(evaluated)
        result << evaluated
      end

      return result
    end

    def eval_index_expression(left, index : PheltObject::Object)
      if left.is_a? PheltObject::Array && index.is_a? PheltObject::Integer
        return eval_array_index_expression(left, index)
      end
      if left.is_a? PheltObject::String && index.is_a? PheltObject::Integer
        return eval_string_index_expression(left, index)
      end
      if left.is_a? PheltObject::Hash && index.is_a? PheltObject::Hashable
        return eval_hash_index_expression(left, index)
      end
      return error("Invalid index operator, #{left.type}")
    end

    def eval_array_index_expression(array : PheltObject::Array, index : PheltObject::Integer)
      index = index.value
      max = array.elements.size - 1

      if index < 0 || index > max
        return NULL
      end

      return array.elements[index]
    end

    def eval_string_index_expression(string : PheltObject::String, index : PheltObject::Integer)
      index = index.value
      max = string.value.size - 1

      if index < 0 || index > max
        return NULL
      end

      return PheltObject::String.new(string.value[index].to_s)
    end

    def eval_hash_index_expression(hash : PheltObject::Hash, index : PheltObject::Hashable)
      unless index.is_a? PheltObject::Hashable
        return error("Cannot use a #{index.type} as a hash key")
      end

      if hash.pairs.has_key? index.hash_key
        return hash.pairs[index.hash_key].value
      else
        return NULL
      end
    end

    def eval_object_access_expression(object : PheltObject::Object, index : PheltObject::String, env : PheltObject::Environment, args : Array(PheltObject::Object)? = nil)
      case object
      when PheltObject::Hash
        return eval_internal_object_access(object, index, env, args)
      when PheltObject::String
        return eval_internal_object_access(object, index, env, args)
      when PheltObject::Number
        return eval_internal_object_access(object, index, env, args)
      when PheltObject::Array
        return eval_internal_object_access(object, index, env, args)
      else
        return error("Unhandled object access for #{object.type}")
      end
    end

    def eval_internal_object_access(object : PheltObject::Object, index : PheltObject::String, env : PheltObject::Environment, args : Array(PheltObject::Object)?)
      if object.is_a? PheltObject::Hash
        if object.pairs.has_key? index.hash_key
          accessed = object.pairs[index.hash_key].value
          if accessed.is_a? PheltObject::Function
            args = [] of PheltObject::Object if args.nil?
            return apply_function(accessed, args, env)
          else
            return accessed
          end
        end
      end

      if args.nil?
        args = [object] of PheltObject::Object
      else
        args.unshift object
      end

      object_internal = object.type.capitalize
      object_methods = env.get(object_internal)

      if object_methods.is_a? PheltObject::Hash
        if object_methods.pairs.has_key? index.hash_key
          accessed = object_methods.pairs[index.hash_key].value
          if accessed.is_a? PheltObject::Function
            return apply_function(accessed, args, env)
          else
            return error("Attempt to call non function #{index.value}")
          end
        end
      end

      global_methods = env.get("Object")
      if global_methods.is_a? PheltObject::Hash
        if global_methods.pairs.has_key? index.hash_key
          accessed = global_methods.pairs[index.hash_key].value
          if accessed.is_a? PheltObject::Function
            return apply_function(accessed, args, env)
          else
            return error("Attempt to call non function #{index.value}")
          end
        end
      end

      return error("Undefined function '#{index.value}' for #{object_internal}.")
    end

    def eval_hash_literal(node : AST::HashLiteral, env : PheltObject::Environment)
      pairs = {} of PheltObject::HashKey => PheltObject::HashPair

      node.pairs.each do |key_node, value_node|
        case key_node
        when AST::Identifier
          key = PheltObject::String.new(key_node.value)
        when AST::IntegerLiteral
          key = PheltObject::Integer.new(key_node.value)
        else
          @current_token = key_node.token
          key = error("Cannot use a #{key_node.token.type.downcase} as a hash key")
        end

        unless key.is_a? PheltObject::Hashable
          return key
        end

        value = eval(value_node, env)
        return value if error?(value)

        if key.is_a? PheltObject::Hashable
          pairs[key.hash_key] = PheltObject::HashPair.new(key, value)
        end
      end

      return PheltObject::Hash.new(pairs)
    end

    def eval_if_expression(expression : AST::IfExpression, env : PheltObject::Environment)
      condition = eval(expression.condition, env)
      return condition if error?(condition)
      if truthy?(condition)
        return eval(expression.consequence, env)
      elsif expression.alternative.is_a? AST::BlockStatement
        return eval(expression.alternative.as(AST::BlockStatement), env)
      else
        return NULL
      end
    end

    def eval_program(statements : Array(AST::Statement), env : PheltObject::Environment)
      result = NULL

      @current_block = statements

      statements.each do |statement|
        @current_token = statement.token
        result = eval(statement, env)
        if result.is_a? PheltObject::Return
          return result.value
        elsif result.is_a? PheltObject::Error
          return result
        end
      end

      result
    end

    def eval_block_statement(block : AST::BlockStatement, env : PheltObject::Environment)
      result = NULL

      @current_block = block.statements

      block.statements.each do |statement|
        @current_token = statement.token
        result = eval(statement, env)

        if result.is_a? PheltObject::Return | PheltObject::Error
          return result
        end
      end

      result
    end

    def eval_prefix_expression(node : AST::PrefixExpression, right : PheltObject::Object, env : PheltObject::Environment)
      case node.operator
      when "!"
        return eval_bang_operator_expression(right)
      when "-"
        return eval_minus_prefix_operator_expression(right)
      when "--"
        return eval_indecrement_prefix_operator_expression(node, right, env)
      when "++"
        return eval_indecrement_prefix_operator_expression(node, right, env)
      else
        return NULL
      end
    end

    def eval_bang_operator_expression(right : PheltObject::Object)
      case right
      when TRUE
        FALSE
      when FALSE
        TRUE
      when NULL
        TRUE
      else
        FALSE
      end
    end

    def eval_minus_prefix_operator_expression(right : PheltObject::Object)
      return PheltObject::Integer.new(-right.value) if right.is_a? PheltObject::Integer
      return PheltObject::Float.new(-right.value) if right.is_a? PheltObject::Float
      return error("Unkown operator -#{right.type}")
    end

    def eval_indecrement_prefix_operator_expression(node : AST::PrefixExpression, right : PheltObject::Object, env : PheltObject::Environment)
      right = node.right

      if right.is_a? AST::Identifier
        @current_token = right.token
        if !env.exists?(right.value)
          return error("Undefined identifier #{right.value}")
        end
        right_obj = env.get(right.value)
      else
        right_obj = eval(right, env)
      end

      if right_obj.is_a? PheltObject::Number
        case node.operator
        when "++"
          value = right_obj.value + 1
        when "--"
          value = right_obj.value - 1
        else
          value = right_obj.value
        end

        value = PheltObject::Integer.new(value) if value.is_a? Int
        value = PheltObject::Float.new(value) if value.is_a? Float

        if right.is_a? AST::Identifier
          env.set(right.value, value)
        end

        return value
      end

      return error("Unkown indecrement prefix operator #{node.operator}.")
    end

    def eval_infix_expression(operator : String, left : PheltObject::Object, right : PheltObject::Object)
      if left.is_a?(PheltObject::Number) && right.is_a?(PheltObject::Number)
        return eval_number_infix_expression(operator, left, right)
      end

      if left.is_a?(PheltObject::String) && right.is_a?(PheltObject::String)
        return eval_string_infix_expression(operator, left, right)
      end

      if operator == "=="
        return bool_to_boolean(left == right)
      end

      if operator == "!="
        return bool_to_boolean(left != right)
      end

      return error("Unkown operator #{left.type} #{operator} #{right.type}")
    end

    def eval_assignment_infix_expression(operator : String, left : AST::Expression, right : PheltObject::Object, env : PheltObject::Environment)
      if left.is_a?(AST::Expression) && right.is_a?(PheltObject::Number)
        return eval_number_assignment_infix_expression(operator, left, right, env)
      end

      if left.is_a?(AST::Expression) && right.is_a?(PheltObject::String)
        return eval_string_assignment_infix_expression(operator, left, right, env)
      end

      if left.is_a?(AST::Expression) && right.is_a?(PheltObject::Object)
        return eval_broad_assignment_infix_expression(operator, left, right, env)
      end

      return error("Unkown assignment operator #{operator}")
    end

    def eval_indecrement_infix_expression(operator : String, left : AST::Expression, env : PheltObject::Environment)
      if left.is_a? AST::Identifier
        @current_token = left.token
        if !env.exists?(left.value)
          return error("Undefined identifier #{left.value}")
        end
        left_obj = env.get(left.value)
      else
        left_obj = eval(left, env)
      end

      if left_obj.is_a?(PheltObject::Number)
        left_val = left_obj.value

        case operator
        when "++"
          value = left_val + 1
        when "--"
          value = left_val - 1
        else
          value = left_val
        end

        value = PheltObject::Integer.new(value.to_i64) if value.is_a? Int
        value = PheltObject::Float.new(value.to_f64) if value.is_a? Float

        if left.is_a? AST::Identifier
          env.set(left.value, value)
        end

        return PheltObject::Integer.new(left_val.to_i64) if left_val.is_a? Int
        return PheltObject::Float.new(left_val.to_f64) if left_val.is_a? Float
      end

      return error("Unkown indecrement infix operator #{operator}")
    end

    def eval_number_infix_expression(operator : String, left : PheltObject::Number, right : PheltObject::Number)
      if left.is_a?(PheltObject::Number) && right.is_a?(PheltObject::Number)
        left_val = left.value
        right_val = right.value

        case operator
        when "+"
          value = left_val + right_val
          value = value.to_i64 if value % 1 == 0
        when "-"
          value = left_val - right_val
          value = value.to_i64 if value % 1 == 0
        when "*"
          value = left_val * right_val
          value = value.to_i64 if value % 1 == 0
        when "/"
          value = left_val / right_val
          value = value.to_i64 if value % 1 == 0
        when "%"
          value = left_val.to_f64 % right_val.to_f64
          value = value.to_i64 if value % 1 == 0
        when "<"
          value = left_val < right_val
        when ">"
          value = left_val > right_val
        when "<="
          value = left_val <= right_val
        when ">="
          value = left_val >= right_val
        when "=="
          value = left_val == right_val
        when "!="
          value = left_val != right_val
        else
          value = error("Unkown operator #{left.type} #{operator} #{right.type}")
        end

        return PheltObject::Integer.new(value.to_i64) if value.is_a? Int
        return PheltObject::Float.new(value.to_f64) if value.is_a? Float
        return bool_to_boolean(value) if value.is_a? Bool
      end
      return error("Unkown operator #{left.type} #{operator} #{right.type}")
    end

    def eval_number_assignment_infix_expression(operator : String, left : AST::Expression, right : PheltObject::Number, env : PheltObject::Environment)
      if left.is_a?(AST::Identifier) && right.is_a?(PheltObject::Number)
        if !env.exists?(left.value)
          @current_token = left.token
          return error("Undefined identifier #{left.value}")
        end

        left_obj = env.get(left.value)

        if left_obj.is_a?(PheltObject::Number)
          left_val = left_obj.value
          right_val = right.value

          case operator
          when "="
            value = right_val
          when "+="
            value = left_val + right_val
          when "-="
            value = left_val - right_val
          when "*="
            value = left_val * right_val
          when "/="
            value = left_val / right_val
          else
            return error("Unkown assignment operator #{operator} for #{left_obj.type}")
          end

          value = PheltObject::Integer.new(value.to_i64) if value.is_a? Int
          value = PheltObject::Float.new(value.to_f64) if value.is_a? Float

          env.set(left.value, value)

          return value
        end
      end
      return error("Unkown assignment operator for #{left.class} #{operator} #{right.type}")
    end

    def eval_broad_assignment_infix_expression(operator : String, left : AST::Expression, right : PheltObject::Object, env : PheltObject::Environment)
      if left.is_a?(AST::Identifier) && right.is_a?(PheltObject::Object)
        if !env.exists?(left.value)
          @current_token = left.token
          return error("Undefined identifier #{left.value}")
        end

        left_obj = env.get(left.value)

        case operator
        when "="
          value = right
        else
          return error("Unkown assignment operator #{operator} for #{left_obj.type}")
        end

        env.set(left.value, value)

        return value
      end
      return error("Unkown assignment operator for #{left.class} #{operator} #{right.type}")
    end

    def eval_string_infix_expression(operator : String, left : PheltObject::String, right : PheltObject::String)
      if left.is_a?(PheltObject::String) && right.is_a?(PheltObject::String)
        left_val = left.value
        right_val = right.value

        case operator
        when "+"
          value = left_val + right_val
        else
          value = error("Unkown operator #{left.type} #{operator} #{right.type}")
        end

        return PheltObject::String.new(value) if value.is_a? String
      end
      return error("Unkown operator #{left.type} #{operator} #{right.type}")
    end

    def eval_string_assignment_infix_expression(operator : String, left : AST::Expression, right : PheltObject::String, env : PheltObject::Environment)
      if left.is_a?(AST::Identifier) && right.is_a?(PheltObject::String)
        if !env.exists?(left.value)
          @current_token = left.token
          return error("Undefined identifier #{left.value}")
        end

        left_obj = env.get(left.value)

        if left_obj.is_a?(PheltObject::String)
          left_val = left_obj.value
          right_val = right.value

          case operator
          when "+="
            value = left_val + right_val
          else
            return error("Unkown assignment operator #{operator} for #{left_obj.type}")
          end

          value = PheltObject::String.new(value)

          env.set(left.value, value)

          return value
        end
      end
      return error("Unkown assignment operator for #{left.class} #{operator} #{right.type}")
    end

    def error?(value)
      return true if value.is_a? PheltObject::Error
      return false
    end

    def error(error : String)
      pretty = "\nEvaluation Error: #{error}".colorize(:red).to_s + "\n\n"

      lines = @program.orig.as(String).lines
      line = "  #{@current_token.line} | "
      error_line = @current_token.line - 1

      pretty += "#{line.colorize(:dark_gray).to_s}#{lines[error_line]}\n"
      pretty += (" " * ((@current_token.column - 1) + line.size)) + "^".colorize(:green).to_s

      pretty += "\n"

      PheltObject::Error.new(error, pretty, @current_token.line, @current_token.column)
    end
  end
end
