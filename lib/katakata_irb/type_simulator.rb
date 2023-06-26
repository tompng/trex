require 'ripper'
require 'set'
require_relative 'types'
require_relative 'scope'

class KatakataIrb::TypeSimulator
  class DigTarget
    def initialize(parents, receiver, &block)
      @dig_ids = parents.to_h { [_1.node_id, true] }
      @target_id = receiver.node_id
      @block = block
    end

    def dig?(node) = @dig_ids[node.node_id]
    def target?(node) = @target_id == node.node_id
    def resolve(type, scope)
      @block.call type, scope
    end
  end

  module ASTNodeMatcher
    refine RubyVM::AbstractSyntaxTree::Node do
      def deconstruct_keys(_keys)
        { type: type, children: children }
      end
    end
  end
  using ASTNodeMatcher

  OBJECT_METHODS = {
    to_s: KatakataIrb::Types::STRING,
    to_str: KatakataIrb::Types::STRING,
    to_a: KatakataIrb::Types::ARRAY,
    to_ary: KatakataIrb::Types::ARRAY,
    to_h: KatakataIrb::Types::HASH,
    to_hash: KatakataIrb::Types::HASH,
    to_i: KatakataIrb::Types::INTEGER,
    to_int: KatakataIrb::Types::INTEGER,
    to_f: KatakataIrb::Types::FLOAT,
    to_c: KatakataIrb::Types::COMPLEX,
    to_r: KatakataIrb::Types::RATIONAL
  }

  def initialize(dig_targets)
    @dig_targets = dig_targets
  end

  def simulate_evaluate(node, scope, case_target: nil)
    result = simulate_evaluate_inner(node, scope, case_target: case_target)
    @dig_targets.resolve result, scope if @dig_targets.target?(node)
    result
  end

  def simulate_evaluate_inner(node, scope, case_target: nil)
    sexp = node
    type = node.type
    children = node.children
    case type
    in :BLOCK
      children.map { simulate_evaluate _1, scope }.last
    in [:def | :defs,]
      sexp in [:def, _method_name_exp, params, body_stmt]
      sexp in [:defs, receiver_exp, _dot_exp, _method_name_exp, params, body_stmt]
      if receiver_exp
        receiver_exp in [:paren, receiver_exp]
        self_type = simulate_evaluate receiver_exp, scope
      else
        current_self_types = scope.self_type.types
        self_types = current_self_types.map do |type|
          if type.is_a?(KatakataIrb::Types::SingletonType) && type.module_or_class.is_a?(Class)
            KatakataIrb::Types::InstanceType.new type.module_or_class
          else
            type
          end
        end
        self_type = KatakataIrb::Types::UnionType[*self_types]
      end
      if @dig_targets.dig? sexp
        params in [:paren, params]
        params ||= [:params, nil, nil, nil, nil, nil, nil, nil] # params might be nil in ruby 3.0
        params_table = extract_param_names(params).to_h { [_1, KatakataIrb::Types::NIL] }
        method_scope = KatakataIrb::Scope.new(
          scope,
          { **params_table, KatakataIrb::Scope::SELF => self_type, KatakataIrb::Scope::BREAK_RESULT => nil, KatakataIrb::Scope::NEXT_RESULT => nil, KatakataIrb::Scope::RETURN_RESULT => nil },
          trace_lvar: false
        )
        evaluate_assign_params params, [], method_scope
        method_scope.conditional { evaluate_param_defaults params, _1 }
        simulate_evaluate body_stmt, method_scope
        method_scope.merge_jumps
        scope.update method_scope
      end
      KatakataIrb::Types::SYMBOL
    in :NIL
      KatakataIrb::Types::NIL
    in :TRUE
      KatakataIrb::Types::TRUE
    in :FALSE
      KatakataIrb::Types::FALSE
    in :LIT
      KatakataIrb::Types::InstanceType.new children.first.class
    in :STR | :XSTR
      KatakataIrb::Types::STRING
    in :DREGX | :DSTR | :DXSTR | :DSYM
      _s, statement, list = children
      [statement, *list&.children].each {
        simulate_evaluate _1.children.first, scope if _1.type == :EVSTR
      }
      case type
      when :DREGX
        KatakataIrb::Types::REGEXP
      when :DSYM
        KatakataIrb::Types::SYMBOL
      else
        KatakataIrb::Types::STRING
      end
    in :BACK_REF
      KatakataIrb::Types::UnionType[KatakataIrb::Types::STRING, KatakataIrb::Types::NIL]
    in :ZLIST
      KatakataIrb::Types::ARRAY
    in :LIST
      types = children.compact.map do
        simulate_evaluate _1, scope
      end
      KatakataIrb::Types::InstanceType.new Array, Elem: KatakataIrb::Types::UnionType[*types]
    in :HASH
      hash_entries_to_type evaluate_hash_entries(node, scope)
    in :ARGSPUSH | :ARGSCAT
      args = evaluate_args(node, scope)
      types = args.flat_map do |elem|
        case elem
        when KatakataIrb::Types::Splat
          array_elem, non_array = partition_to_array elem.item.nonnillable, :to_a
          [*array_elem, *non_array]
        when Array
          hash_entries_to_type(elem)
        else
          elem
        end
      end
      elem_type = KatakataIrb::Types::UnionType[*types]
      KatakataIrb::Types::InstanceType.new(Array, Elem: elem_type)
    in [:paren | :ensure | :else, statements]
      statements.map { simulate_evaluate _1, scope }.last
    in [:const_path_ref, receiver, [:@const, name,]]
      r = simulate_evaluate receiver, scope
      r.is_a?(KatakataIrb::Types::SingletonType) ? KatakataIrb::BaseScope.type_of { r.module_or_class.const_get name } : KatakataIrb::Types::NIL
    in [:__var_ref_or_call, [type, name, pos]]
      sexp = scope.has?(name) ? [:var_ref, [type, name, pos]] : [:vcall, [:@ident, name, pos]]
      simulate_evaluate sexp, scope
    in [:var_ref, [:@kw, name,]]
      case name
      in 'self'
        scope.self_type
      in 'true'
        KatakataIrb::Types::TRUE
      in 'false'
        KatakataIrb::Types::FALSE
      in 'nil'
        KatakataIrb::Types::NIL
      in '__FILE__'
        KatakataIrb::Types::STRING
      in '__LINE__'
        KatakataIrb::Types::INTEGER
      in '__ENCODING__'
        KatakataIrb::Types::InstanceType.new Encoding
      end
    in [:var_ref, [:@const | :@ivar | :@cvar | :@gvar | :@ident, name,]]
      scope[name] || KatakataIrb::Types::NIL
    in [:const_ref, [:@const, name,]]
      scope[name] || KatakataIrb::Types::NIL
    in [:aref, receiver, args]
      receiver_type = simulate_evaluate receiver, scope if receiver
      args, kwargs, _block = retrieve_method_args args
      args_type = args.map do |arg|
        if arg.is_a? KatakataIrb::Types::Splat
          simulate_evaluate arg.item, scope
          nil # TODO: splat
        else
          simulate_evaluate arg, scope
        end
      end
      simulate_call receiver_type, :[], args_type, kwargs_type(kwargs, scope), nil
    in :VCALL
      simulate_call scope.self_type, children.first, [], nil, nil
    in :FCALL
      name, list = children
      evaluate_call scope.self_type, name, list, scope: scope
    in :CALL | :QCALL
      receiver, name, list = children
      receiver_type = simulate_evaluate receiver, scope
      optional_chain = type == :QCALL
      evaluate_call receiver_type, name, list, scope: scope, optional_chain: type == :QCALL
    in :ITER
      call, block = children
      receiver, method, list, optional_chain = (
        case call.type
        in :FCALL
          [scope.self_type, call.children[0], call.children[1], false]
        in :CALL | :QCALL
          [simulate_evaluate(call.children[0], scope), call.children[1], call.children[2], type == :QCALL]
        end
      )
      evaluate_call receiver, method, list, scope: scope, block: block, optional_chain: optional_chain
    in :OPCALL
      a, op, b = node.children
      atype = simulate_evaluate a, scope
      args = b ? [simulate_evaluate(b.children.first, scope)] : []
      simulate_call atype, op, args, nil, nil
    in [:lambda, params, statements]
      params in [:paren, params] # ->{}, -> do end
      statements in [:bodystmt, statements, _unknown, _unknown, _unknown] # -> do end
      params in [:paren, params]
      params_table = extract_param_names(params).to_h { [_1, KatakataIrb::Types::NIL] }
      block_scope = KatakataIrb::Scope.new scope, { **params_table, KatakataIrb::Scope::BREAK_RESULT => nil, KatakataIrb::Scope::NEXT_RESULT => nil, KatakataIrb::Scope::RETURN_RESULT => nil }
      block_scope.conditional do |s|
        evaluate_assign_params params, [], s
        s.conditional { evaluate_param_defaults params, _1 }
        statements.each { simulate_evaluate _1, s }
      end
      block_scope.merge_jumps
      scope.update block_scope
      KatakataIrb::Types::ProcType.new
    in :DVAR | :LVAR | :GVAR | :IVAR | :CVAR
      children => [name]
      scope[name]
    in :LASGN | :GASGN | :IASGN | :CVASGN
      children => [name, value]
      scope[name] = simulate_evaluate(value, scope)
    in [:assign, [:aref_field, receiver, key], value]
      simulate_evaluate receiver, scope
      args, kwargs, _block = retrieve_method_args key
      args.each do |arg|
        item = arg.is_a?(KatakataIrb::Types::Splat) ? arg.item : arg
        simulate_evaluate item, scope
      end
      kwargs_type kwargs, scope
      simulate_evaluate value, scope
    in [:assign, [:field, receiver, period, [:@ident,]], value]
      simulate_evaluate receiver, scope
      if period in [:@op, '&.',]
        scope.conditional { simulate_evaluate value, scope }
      else
        simulate_evaluate value, scope
      end
    in [:opassign, target, [:@op, op,], value]
      op = op.to_s.delete('=').to_sym
      if target in [:var_field, *field]
        receiver = [:var_ref, *field]
      elsif target in [:field, *field]
        receiver = [:call, *field]
      elsif target in [:aref_field, *field]
        receiver = [:aref, *field]
      else
        receiver = target
      end
      simulate_evaluate [:assign, target, [:binary, receiver, op, value]], scope
    in [:assign, target, value]
      simulate_evaluate target, scope
      simulate_evaluate value, scope
    in [:massign, targets, value]
      targets in [:mlhs, *targets] # (a,b) = value
      rhs = simulate_evaluate value, scope
      evaluate_massign targets, rhs, scope
      rhs
    in [:mrhs_new_from_args | :mrhs_add_star,]
      values, = evaluate_mrhs sexp, scope
      KatakataIrb::Types::InstanceType.new Array, Elem: KatakataIrb::Types::UnionType[*values]
    in [:ifop, cond, tval, fval]
      simulate_evaluate cond, scope
      KatakataIrb::Types::UnionType[*scope.run_branches(
        -> { simulate_evaluate tval, _1 },
        -> { simulate_evaluate fval, _1 }
      )]
    in [:if_mod | :unless_mod, cond, statement]
      simulate_evaluate cond, scope
      KatakataIrb::Types::UnionType[scope.conditional { simulate_evaluate statement, _1 }, KatakataIrb::Types::NIL]
    in [:if | :unless | :elsif, cond, statements, else_statement]
      simulate_evaluate cond, scope
      results = scope.run_branches(
        ->(s) { statements.map { simulate_evaluate _1, s }.last },
        ->(s) { else_statement ? simulate_evaluate(else_statement, s) : KatakataIrb::Types::NIL }
      )
      results.empty? ? KatakataIrb::Types::NIL : KatakataIrb::Types::UnionType[*results]
    in [:while | :until, cond, statements]
      inner_scope = KatakataIrb::Scope.new scope, { KatakataIrb::Scope::BREAK_RESULT => nil }, passthrough: true
      simulate_evaluate cond, inner_scope
      inner_scope.conditional { |s| statements.each { simulate_evaluate _1, s } }
      inner_scope.merge_jumps
      scope.update inner_scope
      breaks = inner_scope[KatakataIrb::Scope::BREAK_RESULT]
      breaks ? KatakataIrb::Types::UnionType[breaks, KatakataIrb::Types::NIL] : KatakataIrb::Types::NIL
    in [:while_mod | :until_mod, cond, statement]
      inner_scope = KatakataIrb::Scope.new scope, { KatakataIrb::Scope::BREAK_RESULT => nil }, passthrough: true
      simulate_evaluate cond, inner_scope
      inner_scope.conditional { |s| simulate_evaluate statement, s }
      inner_scope.merge_jumps
      scope.update inner_scope
      breaks = inner_scope[KatakataIrb::Scope::BREAK_RESULT]
      breaks ? KatakataIrb::Types::UnionType[breaks, KatakataIrb::Types::NIL] : KatakataIrb::Types::NIL
    in [:break | :next | :return => jump_type, value]
      internal_key = jump_type == :break ? KatakataIrb::Scope::BREAK_RESULT : jump_type == :next ? KatakataIrb::Scope::NEXT_RESULT : KatakataIrb::Scope::RETURN_RESULT
      if value.empty?
        jump_value = KatakataIrb::Types::NIL
      else
        values, kw = evaluate_mrhs value, scope
        values << kw if kw
        jump_value = values.size == 1 ? values.first : KatakataIrb::Types::InstanceType.new(Array, Elem: KatakataIrb::Types::UnionType[*values])
      end
      scope.terminate_with internal_key, jump_value
      KatakataIrb::Types::NIL
    in [:return0]
      scope.terminate_with KatakataIrb::Scope::RETURN_RESULT, KatakataIrb::Types::NIL
      KatakataIrb::Types::NIL
    in [:yield, args]
      evaluate_mrhs args, scope
      KatakataIrb::Types::OBJECT
    in [:yield0]
      KatakataIrb::Types::OBJECT
    in [:redo | :retry]
      scope.terminate
    in [:zsuper]
      KatakataIrb::Types::OBJECT
    in [:super, args]
      args, kwargs, _block = retrieve_method_args args
      args.each do |arg|
        item = arg.is_a?(KatakataIrb::Types::Splat) ? arg.item : arg
        simulate_evaluate item, scope
      end
      kwargs_type kwargs, scope
      KatakataIrb::Types::OBJECT
    in [:begin, body_stmt]
      simulate_evaluate body_stmt, scope
    in [:bodystmt, statements, rescue_stmt, _unknown, ensure_stmt]
      statements = [statements] if statements in [Symbol,] # oneliner-def body
      rescue_scope = KatakataIrb::Scope.new scope, { KatakataIrb::Scope::RAISE_BREAK => nil }, passthrough: true if rescue_stmt
      return_type = statements.map { simulate_evaluate _1, rescue_scope || scope }.last
      if rescue_stmt
        rescue_scope.merge_jumps
        scope.update rescue_scope
        return_type = KatakataIrb::Types::UnionType[return_type, scope.conditional { simulate_evaluate rescue_stmt, _1 }]
      end
      simulate_evaluate ensure_stmt, scope if ensure_stmt
      return_type
    in [:rescue, error_class_stmts, error_var_stmt, statements, rescue_stmt]
      return_type = scope.conditional do |s|
        if error_var_stmt in [:var_field, [:@ident, error_var,]]
          if (error_class_stmts in [:mrhs_new_from_args, Array => stmts, stmt])
            error_class_stmts = [*stmts, stmt]
          end
          error_classes = (error_class_stmts || []).flat_map { simulate_evaluate _1, s }.uniq
          error_types = error_classes.filter_map { KatakataIrb::Types::InstanceType.new _1.module_or_class if _1.is_a?(KatakataIrb::Types::SingletonType) }
          error_types << KatakataIrb::Types::InstanceType.new(StandardError) if error_types.empty?
          s[error_var] = KatakataIrb::Types::UnionType[*error_types]
        end
        statements.map { simulate_evaluate _1, s }.last
      end
      if rescue_stmt
        return_type = KatakataIrb::Types::UnionType[return_type, scope.conditional { simulate_evaluate rescue_stmt, _1 }]
      end
      return_type
    in [:rescue_mod, statement1, statement2]
      rescue_scope = KatakataIrb::Scope.new scope, { KatakataIrb::Scope::RAISE_BREAK => nil }, passthrough: true
      a = simulate_evaluate statement1, rescue_scope
      rescue_scope.merge_jumps
      scope.update rescue_scope
      b = scope.conditional { simulate_evaluate statement2, _1 }
      KatakataIrb::Types::UnionType[a, b]
    in [:module, module_stmt, body_stmt]
      module_types = simulate_evaluate(module_stmt, scope).types.grep(KatakataIrb::Types::SingletonType)
      module_types << KatakataIrb::Types::MODULE if module_types.empty?
      module_scope = KatakataIrb::Scope.new(scope, { KatakataIrb::Scope::SELF => KatakataIrb::Types::UnionType[*module_types], KatakataIrb::Scope::BREAK_RESULT => nil, KatakataIrb::Scope::NEXT_RESULT => nil, KatakataIrb::Scope::RETURN_RESULT => nil }, trace_cvar: false, trace_ivar: false, trace_lvar: false)
      result = simulate_evaluate body_stmt, module_scope
      scope.update module_scope
      result
    in [:sclass, klass_stmt, body_stmt]
      klass_types = simulate_evaluate(klass_stmt, scope).types.filter_map do |type|
        KatakataIrb::Types::SingletonType.new type.klass if type.is_a? KatakataIrb::Types::InstanceType
      end
      klass_types = [KatakataIrb::Types::CLASS] if klass_types.empty?
      sclass_scope = KatakataIrb::Scope.new(scope, { KatakataIrb::Scope::SELF => KatakataIrb::Types::UnionType[*klass_types], KatakataIrb::Scope::BREAK_RESULT => nil, KatakataIrb::Scope::NEXT_RESULT => nil, KatakataIrb::Scope::RETURN_RESULT => nil }, trace_cvar: false, trace_ivar: false, trace_lvar: false)
      result = simulate_evaluate body_stmt, sclass_scope
      scope.update sclass_scope
      result
    in [:class, klass_stmt, superclass_stmt, body_stmt]
      klass_types = simulate_evaluate(klass_stmt, scope).types
      klass_types += simulate_evaluate(superclass_stmt, scope).types if superclass_stmt
      klass_types = klass_types.select do |type|
        type.is_a?(KatakataIrb::Types::SingletonType) && type.module_or_class.is_a?(Class)
      end
      klass_types << KatakataIrb::Types::CLASS if klass_types.empty?
      klass_scope = KatakataIrb::Scope.new(scope, { KatakataIrb::Scope::SELF => KatakataIrb::Types::UnionType[*klass_types], KatakataIrb::Scope::BREAK_RESULT => nil, KatakataIrb::Scope::NEXT_RESULT => nil, KatakataIrb::Scope::RETURN_RESULT => nil }, trace_cvar: false, trace_ivar: false, trace_lvar: false)
      result = simulate_evaluate body_stmt, klass_scope
      scope.update klass_scope
      result
    in [:for, fields, enum, statements]
      fields = [fields] if fields in [:var_field | :field | :aref_field,]
      params = [:params, fields, nil, nil, nil, nil, nil, nil]
      enum = simulate_evaluate enum, scope
      extract_param_names(params).each { scope[_1] = KatakataIrb::Types::NIL }
      response = simulate_call enum, :first, [], nil, nil
      evaluate_assign_params params, [response], scope
      inner_scope = KatakataIrb::Scope.new scope, { KatakataIrb::Scope::BREAK_RESULT => nil }, passthrough: true
      scope.conditional do |s|
        statements.each { simulate_evaluate _1, s }
      end
      inner_scope.merge_jumps
      scope.update inner_scope
      breaks = inner_scope[KatakataIrb::Scope::BREAK_RESULT]
      breaks ? KatakataIrb::Types::UnionType[breaks, enum] : enum
    in [:when, pattern, if_statements, else_statement]
      eval_pattern = lambda do |s, pattern, *rest|
        simulate_evaluate pattern, s
        scope.conditional { eval_pattern.call(_1, *rest) } if rest.any?
      end
      if_branch = lambda do |s|
        eval_pattern.call(s, *pattern)
        if_statements.map { simulate_evaluate _1, s }.last
      end
      else_branch = lambda do |s|
        pattern.each { simulate_evaluate _1, s }
        simulate_evaluate(else_statement, s, case_target: case_target)
      end
      if if_statements && else_statement
        KatakataIrb::Types::UnionType[*scope.run_branches(if_branch, else_branch)]
      else
        KatakataIrb::Types::UnionType[scope.conditional { (if_branch || else_branch).call _1 }, KatakataIrb::Types::NIL]
      end
    in [:in, [:var_field, [:@ident, name,]], if_statements, else_statement]
      scope.never { simulate_evaluate else_statement, scope } if else_statement
      scope[name] = case_target || KatakataIrb::Types::OBJECT
      if_statements ? if_statements.map { simulate_evaluate _1, scope }.last : KatakataIrb::Types::NIL
    in [:in, pattern, if_statements, else_statement]
      pattern_scope = KatakataIrb::Scope.new(scope, { KatakataIrb::Scope::PATTERNMATCH_BREAK => nil }, passthrough: true)
      results = pattern_scope.run_branches(
        ->(s) {
          match_pattern case_target, pattern, s
          if_statements ? if_statements.map { simulate_evaluate _1, s }.last : KatakataIrb::Types::NIL
        },
        ->(s) {
          else_statement ? simulate_evaluate(else_statement, s, case_target: case_target) : KatakataIrb::Types::NIL
        }
      )
      pattern_scope.merge_jumps
      scope.update pattern_scope
      KatakataIrb::Types::UnionType[*results]
    in [:case, target_exp, match_exp]
      target = target_exp ? simulate_evaluate(target_exp, scope) : KatakataIrb::Types::NIL
      simulate_evaluate match_exp, scope, case_target: target
    in [:void_stmt]
      KatakataIrb::Types::NIL
    in [:dot2 | :dot3, range_beg, range_end]
      beg_type = simulate_evaluate range_beg, scope if range_beg
      end_type = simulate_evaluate range_end, scope if range_end
      elem = (KatakataIrb::Types::UnionType[*[beg_type, end_type].compact]).nonnillable
      KatakataIrb::Types::InstanceType.new Range, { Elem: elem }
    in [:top_const_ref, [:@const, name,]]
      KatakataIrb::BaseScope.type_of { Object.const_get name }
    in [:string_concat, a, b]
      simulate_evaluate a, scope
      simulate_evaluate b, scope
      KatakataIrb::Types::STRING
    in [:defined, expression]
      scope.conditional { simulate_evaluate expression, _1 }
      KatakataIrb::Types::UnionType[KatakataIrb::Types::STRING, KatakataIrb::Types::NIL]
    else
      $node = node
      KatakataIrb.log_puts :NOMATCH
      KatakataIrb.log_puts node.inspect
      KatakataIrb.log_puts node.children.inspect
      KatakataIrb.log_puts
      KatakataIrb::Types::NIL
    end
  end

  def evaluate_hash_entries(node, scope)
    node.children.first.children.each_slice(2).filter_map do |k, v|
      next unless v
      next [nil, simulate_evaluate(v, scope)] unless k

      key = k.type == :LIT && k.children.first.is_a?(Symbol) ? k.children.first : simulate_evaluate(k, scope)
      value = simulate_evaluate v, scope
      [key, value]
    end
  end

  def hash_entries_to_type(entries)
    keys = []
    values = []
    entries.each do |k, v|
      next unless k # TODO: splat
      keys << (k.is_a?(Symbol) ? KatakataIrb::Types::SYMBOL : k)
      values << v
    end
    key_type = KatakataIrb::Types::UnionType[*keys]
    value_type = KatakataIrb::Types::UnionType[*values]
    KatakataIrb::Types::InstanceType.new Hash, K: key_type, V: value_type
  end

  def evaluate_args_block(node, scope)
    if node.nil?
      [[], nil]
    elsif node.type == :BLOCK_PASS
      arg_node, block_node = node.children
      args = evaluate_args arg_node, scope
      block = block_node.type == :LIT ? block_node.children.first : simulate_evaluate(block_node, scope)
      [args, block]
    else
      [evaluate_args(node, scope), nil]
    end
  end

  def evaluate_args(node, scope)
    case node.type
    when :LIST
      args = node.children.compact.map do |value|
        value.type == :HASH ? evaluate_hash_entries(value, scope) : simulate_evaluate(value, scope)
      end
      [args, nil]
    when :ARGSPUSH
      args_node, arg_node = node.children
      args = evaluate_args args_node, scope
      arg = arg_node.type == :HASH ? evaluate_hash_entries(arg_node, scope) : simulate_evaluate(arg_node, scope)
      [[*args, arg], nil]
    when :ARGSCAT
      args_node, splat = node.children
      args = evaluate_args args_node, scope
      [[*args, KatakataIrb::Types::Splat.new(simulate_evaluate(splat, scope))], nil]
    end
  end

  def match_pattern(target, pattern, scope)
    breakable = -> { scope.terminate_with KatakataIrb::Scope::PATTERNMATCH_BREAK, KatakataIrb::Types::NIL }
    types = target.types
    case pattern
    in [:var_field, [:@ident, name,]]
      scope[name] = target
    in [:var_ref,] # in Array, in ^a, in nil
    in [:@int | :@float | :@rational | :@imaginary | :@CHAR | :symbol_literal | :string_literal | :regexp_literal,]
    in [:begin, statement] # in (statement)
      simulate_evaluate statement, scope
      breakable.call
    in [:binary, lpattern, :|, rpattern]
      match_pattern target, lpattern, scope
      scope.conditional { match_pattern target, rpattern, _1 }
      breakable.call
    in [:binary, lpattern, :'=>', [:var_field, [:@ident, name,]] => rpattern]
      if lpattern in [:var_ref, [:@const, _const_name,]]
        const_value = simulate_evaluate lpattern, scope
        if const_value.is_a?(KatakataIrb::Types::SingletonType) && const_value.module_or_class.is_a?(Class)
          scope[name] = KatakataIrb::Types::InstanceType.new const_value.module_or_class
        else
          scope[name] = KatakataIrb::Types::OBJECT
        end
        breakable.call
      else
        match_pattern target, lpattern, scope
        match_pattern target, rpattern, scope
      end
    in [:aryptn, _unknown, items, splat, post_items]
      # TODO: deconstruct keys
      array_types = types.select { _1.is_a?(KatakataIrb::Types::InstanceType) && _1.klass == Array }
      elem = KatakataIrb::Types::UnionType[*array_types.filter_map { _1.params[:Elem] }]
      items&.each do |item|
        match_pattern elem, item, scope
      end
      if splat in [:var_field, [:@ident, name,]]
        scope[name] = KatakataIrb::Types::InstanceType.new Array, Elem: elem
        breakable.call
      end
      post_items&.each do |item|
        match_pattern elem, item, scope
      end
    in [:hshptn, _unknown, items, splat]
      # TODO: deconstruct keys
      hash_types = types.select { _1.is_a?(KatakataIrb::Types::InstanceType) && _1.klass == Hash }
      key_type = KatakataIrb::Types::UnionType[*hash_types.filter_map { _1.params[:K] }]
      value_type = KatakataIrb::Types::UnionType[*hash_types.filter_map { _1.params[:V] }]
      items&.each do |key_pattern, value_pattern|
        if (key_pattern in [:@label, label,]) && !value_pattern
          name = label.delete ':'
          scope[name] = value_type
          breakable.call
        end
        match_pattern value_type, value_pattern, scope if value_pattern
      end
      if splat in [:var_field, [:@ident, name,]]
        scope[name] = KatakataIrb::Types::InstanceType.new Hash, K: key_type, V: value_type
        breakable.call
      end
    in [:if_mod, cond, ifpattern]
      match_pattern target, ifpattern, scope
      simulate_evaluate cond, scope
      breakable.call
    in [:dyna_symbol,]
    in [:const_path_ref,]
    else
      KatakataIrb.log_puts "Unimplemented match pattern: #{pattern}"
    end
  end

  def evaluate_mrhs(sexp, scope)
    args, kwargs, = retrieve_method_args sexp
    values = args.filter_map do |t|
      if t.is_a? KatakataIrb::Types::Splat
        simulate_evaluate t.item, scope
        # TODO
        nil
      else
        simulate_evaluate t, scope
      end
    end
    unless kwargs.empty?
      kvs = kwargs.map do |t|
        case t
        in KatakataIrb::Types::Splat
          simulate_evaluate t.item, scope
          # TODO
          [KatakataIrb::Types::SYMBOL, KatakataIrb::Types::OBJECT]
        in [key, value]
          key_type = (key in [:@label,]) ? KatakataIrb::Types::SYMBOL : simulate_evaluate(key, scope)
          [key_type, simulate_evaluate(value, scope)]
        end
      end
      key_type = KatakataIrb::Types::UnionType[*kvs.map(&:first)]
      value_type = KatakataIrb::Types::UnionType[*kvs.map(&:last)]
      kw = KatakataIrb::Types::InstanceType.new(Hash, K: key_type, V: value_type)
    end
    [values, kw]
  end

  def sized_splat(value, method, size)
    array_elem, non_array = partition_to_array value, method
    values = [KatakataIrb::Types::UnionType[*array_elem, *non_array]]
    values += [array_elem] * (size - 1) if array_elem && size >= 1
    values
  end

  def partition_to_array(value, method)
    arrays, non_arrays = value.types.partition { _1.is_a?(KatakataIrb::Types::InstanceType) && _1.klass == Array }
    non_arrays.select! do |type|
      to_array_result = simulate_call type, method, [], nil, nil, name_match: false
      if to_array_result.is_a?(KatakataIrb::Types::InstanceType) && to_array_result.klass == Array
        arrays << to_array_result
        false
      else
        true
      end
    end
    array_elem = arrays.empty? ? nil : KatakataIrb::Types::UnionType[*arrays.map { _1.params[:Elem] || KatakataIrb::Types::OBJECT }]
    non_array = non_arrays.empty? ? nil : KatakataIrb::Types::UnionType[*non_arrays]
    [array_elem, non_array]
  end

  def evaluate_massign(sexp, values, scope)
    values = sized_splat values, :to_ary, sexp.size unless values.is_a? Array
    rest_index = sexp.find_index { _1 in [:rest_param, ]}
    if rest_index
      pre = rest_index ? sexp[0...rest_index] : sexp
      post = rest_index ? sexp[rest_index + 1..] : []
      sexp[rest_index] in [:rest_param, rest_field]
      rest_values = values[pre.size...values.size - post.size] || []
      rest_type = KatakataIrb::Types::InstanceType.new Array, Elem: KatakataIrb::Types::UnionType[*rest_values]
      pairs = pre.zip(values.first(pre.size)) + [[rest_field, rest_type]] + post.zip(values.last(post.size))
    else
      pairs = sexp.zip values
    end
    pairs.each do |field, value|
      case field
      in [:@ident, name,]
        # block arg mlhs
        scope[name] = value || KatakataIrb::Types::OBJECT
      in [:var_field, [:@gvar | :@ivar | :@cvar | :@ident | :@const, name,]]
        # massign
        scope[name] = value || KatakataIrb::Types::OBJECT
      in [:mlhs, *mlhs]
        evaluate_massign mlhs, value || [], scope
      in [:field, receiver,]
        # (a=x).b, c = value
        simulate_evaluate receiver, scope
      in [:aref_field, *field]
        # (a=x)[i=y, j=z], b = value
        simulate_evaluate [:aref, *field], scope
      in nil
        # a, *, b = value
      end
    end
  end

  def kwargs_type(kwargs, scope)
    return if kwargs.empty?
    keys = []
    values = []
    kwargs.each do |kv|
      if kv.is_a? KatakataIrb::Types::Splat
        hash = simulate_evaluate kv.item, scope
        unless hash.is_a?(KatakataIrb::Types::InstanceType) && hash.klass == Hash
          hash = simulate_call hash, :to_hash, [], nil, nil
        end
        if hash.is_a?(KatakataIrb::Types::InstanceType) && hash.klass == Hash
          keys << hash.params[:K] if hash.params[:K]
          values << hash.params[:V] if hash.params[:V]
        end
      else
        key, value = kv
        keys << ((key in [:@label,]) ? KatakataIrb::Types::SYMBOL : simulate_evaluate(key, scope))
        values << simulate_evaluate(value, scope)
      end
    end
    KatakataIrb::Types::InstanceType.new(Hash, K: KatakataIrb::Types::UnionType[*keys], V: KatakataIrb::Types::UnionType[*values])
  end

  def retrieve_method_call(sexp)
    optional = -> { _1 in [:@op, '&.',] }
    case sexp
    in [:fcall | :vcall, [:@ident | :@const | :@kw | :@op, method,]] # hoge
      [nil, method, [], [], nil, false]
    in [:call, receiver, [:@period,] | [:@op, '&.',] | :'::' => dot, :call]
      [receiver, :call, [], [], nil, optional[dot]]
    in [:call, receiver, [:@period,] | [:@op, '&.',] | :'::' => dot, method]
      method => [:@ident | :@const | :@kw | :@op, method,] unless method == :call
      [receiver, method, [], [], nil, optional[dot]]
    in [:command, [:@ident | :@const | :@kw | :@op, method,], args] # hoge 1, 2
      args, kwargs, block = retrieve_method_args args
      [nil, method, args, kwargs, block, false]
    in [:command_call, receiver, [:@period,] | [:@op, '&.',] | :'::' => dot, [:@ident | :@const | :@kw | :@op, method,], args] # a.hoge 1; a.hoge 1, 2;
      args, kwargs, block = retrieve_method_args args
      [receiver, method, args, kwargs, block, optional[dot]]
    in [:method_add_arg, call, args]
      receiver, method, _arg, _kwarg, _block, opt = retrieve_method_call call
      args, kwargs, block = retrieve_method_args args
      [receiver, method, args, kwargs, block, opt]
    in [:method_add_block, call, block]
      receiver, method, args, kwargs, opt = retrieve_method_call call
      [receiver, method, args, kwargs, block, opt]
    end
  end

  def retrieve_method_args(sexp)
    case sexp
    in [:mrhs_add_star, args, star]
      args, = retrieve_method_args args
      [[*args, KatakataIrb::Types::Splat.new(star)], [], nil]
    in [:mrhs_new_from_args, [:args_add_star,] => args]
      args, = retrieve_method_args args
      [args, [], nil]
    in [:mrhs_new_from_args, [:args_add_star,] => args, last_arg]
      args, = retrieve_method_args args
      [[*args, last_arg], [], nil]
    in [:mrhs_new_from_args, args, last_arg]
      [[*args, last_arg], [], nil]
    in [:mrhs_new_from_args, args]
      [args, [], nil]
    in [:args_add_block, [:args_add_star,] => args, block_arg]
      args, kwargs, = retrieve_method_args args
      block_arg = [:void_stmt] if block_arg.nil? # method(*splat, &)
      [args, kwargs, block_arg]
    in [:args_add_block, [*args, [:bare_assoc_hash,] => kw], block_arg]
      block_arg = [:void_stmt] if block_arg.nil? # method(**splat, &)
      _, kwargs = retrieve_method_args kw
      [args, kwargs, block_arg]
    in [:args_add_block, [*args], block_arg]
      block_arg = [:void_stmt] if block_arg.nil? # method(arg, &)
      [args, [], block_arg]
    in [:bare_assoc_hash, kws]
      kwargs = []
      kws.each do |kw|
        if kw in [:assoc_splat, value,]
          kwargs << KatakataIrb::Types::Splat.new(value) if value
        elsif kw in [:assoc_new, [:@label, label,] => key, nil]
          name = label.delete ':'
          kwargs << [key, [:__var_ref_or_call, [name =~ /\A[A-Z]/ ? :@const : :@ident, name, [0, 0]]]]
        elsif kw in [:assoc_new, key, value]
          kwargs << [key, value]
        end
      end
      [[], kwargs, nil]
    in [:args_add_star, *args, [:bare_assoc_hash,] => kwargs]
      args, = retrieve_method_args [:args_add_star, *args]
      _, kwargs = retrieve_method_args kwargs
      [args, kwargs, nil]
    in [:args_add_star, pre_args, star_arg, *post_args]
      pre_args, = retrieve_method_args pre_args if pre_args in [:args_add_star,]
      args = star_arg ? [*pre_args, KatakataIrb::Types::Splat.new(star_arg), *post_args] : pre_args + post_args
      [args, [], nil]
    in [:arg_paren, args]
      args ? retrieve_method_args(args) : [[], [], nil]
    in [[:command | :command_call, ] => command_arg] # method(a b, c), method(a.b c, d)
      [[command_arg], [], nil]
    else
      [[], [], nil]
    end
  end

  def evaluate_call(receiver, method_name, list, scope:, block: nil, optional_chain: false)
    evaluate_method = lambda do |receiver, scope|
      list_args, block_arg = evaluate_args_block(list, scope)
      block ||= block_arg
      args = list_args.map do |elem|
        elem.is_a?(Array) ? hash_entries_to_type(elem) : elem
      end
      if list_args.last.is_a?(Array)
        args.pop
        kwargs = list_args.last.select { _1.is_a? Symbol }
      end

      if block
        if block.is_a?(Symbol)
          call_block_proc = ->(block_args, _self_type) do
            block_receiver, *rest = block_args
            block_receiver ? simulate_call(block_receiver || KatakataIrb::Types::OBJECT, block, rest, nil, nil) : KatakataIrb::Types::OBJECT
          end
        elsif block&.type == :SCOPE
          call_block_proc = ->(block_args, block_self_type) do
            table, args, body = block.children
            scope.conditional do |s|
              if params
                names = extract_param_names(params)
              else
                names = (1..max_numbered_params(body)).map { "_#{_1}" }
                params = [:params, names.map { [:@ident, _1, [0, 0]] }, nil, nil, nil, nil, nil, nil]
              end
              params_table = names.zip(block_args).to_h { [_1, _2 || KatakataIrb::Types::NIL] }
              table = { **params_table, KatakataIrb::Scope::BREAK_RESULT => nil, KatakataIrb::Scope::NEXT_RESULT => nil }
              table[KatakataIrb::Scope::SELF] = block_self_type if block_self_type
              block_scope = KatakataIrb::Scope.new s, table
              evaluate_assign_params params, block_args, block_scope
              block_scope.conditional { evaluate_param_defaults params, _1 } if params
              if type == :do_block
                result = simulate_evaluate body, block_scope
              else
                result = body.map { simulate_evaluate _1, block_scope }.last
              end
              block_scope.merge_jumps
              s.update block_scope
              nexts = block_scope[KatakataIrb::Scope::NEXT_RESULT]
              breaks = block_scope[KatakataIrb::Scope::BREAK_RESULT]
              if block_scope.terminated?
                [KatakataIrb::Types::UnionType[*nexts], breaks]
              else
                [KatakataIrb::Types::UnionType[result, *nexts], breaks]
              end
            end
          end
        else
          call_block_proc = ->(_block_args, _self_type) { KatakataIrb::Types::OBJECT }
        end
      end
      simulate_call receiver, method_name, args_type, kwargs_type(kwargs, scope), call_block_proc
    end
    if !optional_chain
      evaluate_method.call receiver, scope
    elsif receiver_type.nil?
      KatakataIrb::Types::NIL
    else
      result = scope.conditional { evaluate_method.call receiver.nonnillable, _1 }
      if receiver.nillable?
        KatakataIrb::Types::UnionType[result, KatakataIrb::Types::NIL]
      else
        result
      end
    end
  end

  def simulate_call(receiver, method_name, args, kwargs, block, name_match: true)
    methods = KatakataIrb::Types.rbs_methods receiver, method_name.to_sym, args, kwargs, !!block
    block_called = false
    type_breaks = methods.map do |method, given_params, method_params|
      receiver_vars = (receiver in KatakataIrb::Types::InstanceType) ? receiver.params : {}
      free_vars = method.type.free_variables - receiver_vars.keys.to_set
      vars = receiver_vars.merge KatakataIrb::Types.match_free_variables(free_vars, method_params, given_params)
      if block && method.block
        params_type = method.block.type.required_positionals.map do |func_param|
          KatakataIrb::Types.from_rbs_type func_param.type, receiver, vars
        end
        self_type = KatakataIrb::Types.from_rbs_type method.block.self_type, receiver, vars if method.block.self_type
        block_response, breaks = block.call params_type, self_type
        block_called = true
        vars.merge! KatakataIrb::Types.match_free_variables(free_vars - vars.keys.to_set, [method.block.type.return_type], [block_response])
      end
      [KatakataIrb::Types.from_rbs_type(method.type.return_type, receiver, vars || {}), breaks]
    end
    block&.call [], nil unless block_called
    types = type_breaks.map(&:first)
    breaks = type_breaks.map(&:last).compact
    types << OBJECT_METHODS[method_name.to_sym] if name_match && OBJECT_METHODS.has_key?(method_name.to_sym)

    if method_name.to_sym == :new
      receiver.types.each do |type|
        if (type in KatakataIrb::Types::SingletonType) && type.module_or_class.is_a?(Class)
          types << KatakataIrb::Types::InstanceType.new(type.module_or_class)
        end
      end
    end
    KatakataIrb::Types::UnionType[*types, *breaks]
  end

  def extract_param_names(params)
    params => [:params, pre_required, optional, rest, post_required, keywords, keyrest, block]
    names = []
    extract_mlhs = ->(item) do
      case item
      in [:var_field, [:@ident, name,],]
        names << name
      in [:@ident, name,]
        names << name
      in [:mlhs, *items]
        items.each(&extract_mlhs)
      in [:rest_param, item]
        extract_mlhs.call item if item
      in [:field | :aref_field,]
        # a.b, c[i] = value
      in [:excessed_comma]
      in [:args_forward]
      end
    end
    [*pre_required, *post_required].each(&extract_mlhs)
    extract_mlhs.call rest if rest
    optional&.each do |key, _value|
      key => [:@ident, name,]
      names << name
    end
    keywords&.each do |key, _value|
      key => [:@label, label,]
      names << label.delete(':')
    end
    if keyrest in [:kwrest_params, [:@ident, name,]]
      names << name
    end
    if block in [:blockarg, [:@ident, name,]]
      names << name
    end
    names
  end

  def evaluate_assign_params(params, values, scope)
    values = values.dup
    params => [:params, pre_required, optional, rest, post_required, _keywords, keyrest, block]
    size = (pre_required&.size || 0) + (optional&.size || 0) + (post_required&.size || 0) + (rest ? 1 : 0)
    values = sized_splat values.first, :to_ary, size if values.size == 1 && size >= 2
    pre_values = values.shift pre_required.size if pre_required
    post_values = values.pop post_required.size if post_required
    opt_values = values.shift optional.size if optional
    rest_values = values
    evaluate_massign pre_required, pre_values, scope if pre_required
    evaluate_massign optional.map(&:first), opt_values, scope if optional
    if rest in [:rest_param, [:@ident, name,]]
      scope[name] = KatakataIrb::Types::InstanceType.new Array, Elem: KatakataIrb::Types::UnionType[*rest_values]
    end
    evaluate_massign post_required, post_values, scope if post_required
    # TODO: assign keywords
    if keyrest in [:kwrest_param, [:@ident, name,]]
      scope[name] = KatakataIrb::Types::InstanceType.new Hash, K: KatakataIrb::Types::SYMBOL, V: KatakataIrb::Types::OBJECT
    end
    if block in [:blockarg, [:@ident, name,]]
      scope[name] = KatakataIrb::Types::PROC
    end
  end

  def evaluate_param_defaults(params, scope)
    params => [:params, _pre_required, optional, rest, _post_required, keywords, keyrest, block]
    optional&.each do |item, value|
      item => [:@ident, name,]
      scope[name] = simulate_evaluate value, scope
    end
    if rest in [:rest_param, [:@ident, name,]]
      scope[name] = KatakataIrb::Types::ARRAY
    end
    keywords&.each do |key, value|
      key => [:@label, label,]
      name = label.delete ':'
      scope[name] = value ? simulate_evaluate(value, scope) : KatakataIrb::Types::OBJECT
    end
    if keyrest in [:kwrest_param, [:@ident, name,]]
        scope[name] = KatakataIrb::Types::HASH
    end
    if block in [:blockarg, [:@ident, name,]]
      scope[name] = KatakataIrb::Types::PROC
    end
  end

  def self.calculate_binding_scope(binding, parents, target)
    dig_targets = DigTarget.new(parents, target) do |_types, scope|
      return scope
    end
    scope = KatakataIrb::Scope.from_binding(binding)
    new(dig_targets).simulate_evaluate parents[0], scope
    scope
  end

  def self.calculate_receiver(binding, parents, receiver)
    dig_targets = DigTarget.new(parents, receiver) do |type, _scope|
      return type
    end
    lvars = binding.local_variables
    if parents[0] in { type: :SCOPE }
      lvars |= parents[0].children[0]
      parents.shift
    end
    new(dig_targets).simulate_evaluate parents[0], KatakataIrb::Scope.from_binding(binding)
    KatakataIrb::Types::NIL
  end
end
