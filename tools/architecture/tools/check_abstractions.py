"""Targeted Ruby AST regression gate for known execution implementation leaks.

This does not prove that all dependencies are appropriate. Graph triangles are
reported separately for human investigation, without treating them as violations.
"""
from pathlib import Path
from tree_sitter import Language, Parser
import tree_sitter_ruby

OWNERS = ('lib/phronomy/execution/',
          'lib/phronomy/engine/')
PRIVATE_CALLS = {'__execution_scope', '__bind_execution', '__open?',
                 '__cancellation_error', '__map_completion', '__run_async'}
CONSUMERS = {'lib/phronomy/tools/agent.rb', 'lib/phronomy/multi_agent/orchestrator.rb',
             'lib/phronomy/agent/tool_execution/tool_binding.rb'}


def violations(repository):
    parser = Parser(Language(tree_sitter_ruby.language()))
    findings = []
    for path in sorted(Path(repository).glob('lib/**/*.rb')):
        relative = path.relative_to(repository).as_posix()
        if relative.startswith(OWNERS):
            continue
        source = path.read_bytes()
        root = parser.parse(source).root_node
        if root.has_error:
            findings.append({'kind': 'ruby-parse-error', 'file': relative})
            continue
        def text(node):
            return source[node.start_byte:node.end_byte].decode() if node else ''
        def walk(node):
            if node.type == 'call':
                method = text(node.child_by_field_name('method'))
                args = node.child_by_field_name('arguments')
                first = args.named_children[0] if args and args.named_children else None
                indirect = (text(first).lstrip(':').strip('\"\'')
                            if method in {'send', '__send__', 'public_send'} else '')
                if method in PRIVATE_CALLS or indirect in PRIVATE_CALLS:
                    findings.append({'kind': 'private-execution-control-leak',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
                if relative in CONSUMERS and method in {'deferred', 'complete', 'fail'}:
                    findings.append({'kind': 'consumer-settles-result', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
            for child in node.named_children:
                walk(child)
        walk(root)
    return findings
