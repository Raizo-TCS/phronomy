# frozen_string_literal: true

# Use RBS's own parser and lexical resolver; never infer types from Ruby calls.
require "json"
require "pathname"
require "rbs"

class SignatureDependencies
  D = RBS::AST::Declarations
  M = RBS::AST::Members
  NAMED_TYPES = [RBS::Types::ClassInstance, RBS::Types::ClassSingleton,
    RBS::Types::Interface, RBS::Types::Alias].freeze

  def initialize(root)
    @root = Pathname(root).realpath
    @declarations = []
    @references = []
  end

  def location(loc)
    {file: Pathname(loc.buffer.name).relative_path_from(@root).to_s,
     line: loc.start_line, column: loc.start_column}
  end

  def reference(name, loc, context, kind)
    raise "Unresolved RBS type #{name} at #{loc}" unless name.namespace.absolute? && @known_types.include?(name)

    @references << context.merge(location(loc)).merge(
      name: name.to_s.delete_prefix("::"), category: kind, text: loc.source
    )
  end

  def type(ty, context)
    return unless ty

    reference(ty.name, ty.location, context, "type") if NAMED_TYPES.any? { |klass| ty.is_a?(klass) }
    ty.each_type { |child| type(child, context) }
  end

  def parameters(params, context)
    params.each do |param|
      type(param.upper_bound_type, context)
      type(param.lower_bound_type, context)
      type(param.default_type, context)
    end
  end

  def named(node, context, kind)
    reference(node.name, node.location, context, kind)
    node.args.each { |arg| type(arg, context) }
  end

  def declaration(node)
    name = (node.respond_to?(:name) ? node.name : node.new_name).to_s.delete_prefix("::")
    context = {owner: name, member: nil, member_kind: nil}
    @declarations << context.merge(location(node.location)).merge(kind: node.class.name.split("::").last)
    parameters(node.type_params, context) if node.respond_to?(:type_params)
    case node
    when D::Class, D::Module, D::Interface
      named(node.super_class, context, "inheritance") if node.is_a?(D::Class) && node.super_class
      node.self_types.each { |self_type| named(self_type, context, "self_type") } if node.is_a?(D::Module)
      node.members.each do |member|
        if member.is_a?(D::Base)
          declaration(member)
        else
          member(member, context)
        end
      end
    when D::TypeAlias, D::Constant, D::Global
      type(node.type, context)
    when D::ClassAlias, D::ModuleAlias
      reference(node.old_name, node.location, context, "alias")
    else
      raise "Unsupported RBS declaration: #{node.class}"
    end
  end

  def member(node, context)
    context = context.merge(member: node.name.to_s) if node.respond_to?(:name)
    context = context.merge(member_kind: node.kind.to_s) if node.respond_to?(:kind)
    case node
    when M::MethodDefinition
      node.overloads.each do |overload|
        method_type = overload.method_type
        parameters(method_type.type_params, context)
        method_type.each_type { |ty| type(ty, context) }
      end
    when M::Include, M::Extend, M::Prepend
      named(node, context, "mixin")
    when M::AttrReader, M::AttrWriter, M::AttrAccessor,
         M::InstanceVariable, M::ClassInstanceVariable, M::ClassVariable
      type(node.type, context)
    when M::Alias, M::Public, M::Private
      # These contain no explicit type references.
    else
      raise "Unsupported RBS member: #{node.class}"
    end
  end

  def extract
    loader = RBS::EnvironmentLoader.new
    loader.add(path: @root.join("sig")) # Includes development-only _private signatures.
    env = RBS::Environment.from_loader(loader).resolve_type_names
    @known_types = (env.class_decls.keys + env.interface_decls.keys + env.type_alias_decls.keys +
                    env.class_alias_decls.keys).to_set
    files = []
    env.each_rbs_source do |source|
      path = Pathname(source.buffer.name).expand_path
      next unless path.to_s.start_with?(@root.join("sig").to_s + "/")

      files << path.relative_path_from(@root).to_s
      source.declarations.each { |node| declaration(node) }
    end
    expected = @root.glob("sig/**/*.rbs").map { |path| path.relative_path_from(@root).to_s }.sort
    raise "Not all project signatures were loaded" unless files.sort == expected

    {parser: "RBS", version: RBS::VERSION, files: files.sort,
     declarations: @declarations, references: @references}
  end
end

puts JSON.generate(SignatureDependencies.new(ARGV.fetch(0)).extract) if $PROGRAM_NAME == __FILE__
