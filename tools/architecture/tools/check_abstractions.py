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
ADMISSION = {'lib/phronomy/agent/admission.rb',
             'lib/phronomy/agent/execution/initial_preparation.rb'}
PARENT_CALLS = {'teams', 'team_executions', 'assignments', 'handoff_states',
                'validate_team_admission!', 'validate_subagent_admission!', 'validate_handoff_admission!'}


def violations(repository):
    parser = Parser(Language(tree_sitter_ruby.language()))
    findings = []
    for path in sorted(Path(repository).glob('lib/**/*.rb')):
        relative = path.relative_to(repository).as_posix()
        if relative.startswith('lib/phronomy/execution/'):
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
                if method == 'unregister_cancel_callback' or indirect == 'unregister_cancel_callback':
                    findings.append({'kind': 'private-cancellation-registration-leak',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
            # Engine is an allowed owner for the older execution-control gates,
            # but cancellation registration disposal belongs to Execution alone.
            if relative.startswith(OWNERS):
                for child in node.named_children:
                    walk(child)
                return
            persistence_evidence = relative in {
                'lib/phronomy/persistence/snapshot_comparison.rb',
                'lib/phronomy/persistence/save_outcome.rb'}
            if persistence_evidence and node.type == 'constant' and text(node) in {
                    'Agent', 'MultiAgent', 'Workflow', 'RecoveryRules', 'Runtime', 'Engine'}:
                findings.append({'kind': 'persistence-evidence-knows-domain', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if (node.type == 'scope_resolution' and text(node) in {'Phronomy::Recovery', '::Phronomy::Recovery'}
                    or node.type == 'constant' and text(node) == 'RecoveryRules'
                    and not relative.startswith('lib/phronomy/agent/')):
                findings.append({'kind': 'recovery-rules-owner-leak', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            tool_contract = relative.startswith('lib/phronomy/tool/')
            llm_contract = relative.startswith('lib/phronomy/llm_adapter/') and '/backends/' not in relative and '/async/' not in relative
            agent = relative.startswith('lib/phronomy/agent/')
            agent_domain = agent and '/runtime_binding/' not in relative and '/composition/' not in relative
            generation = relative.startswith('lib/phronomy/generation/')
            if generation and node.type == 'constant' and text(node) in {'JsonParser', 'StructuredParser'}:
                findings.append({'kind': 'generation-selects-concrete-parser', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if agent_domain and node.type == 'constant' and text(node) in {'DefaultPolicy', 'AsyncClient'}:
                findings.append({'kind': 'agent-selects-concrete-policy-or-client', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            workflow_domain = relative.startswith('lib/phronomy/workflow/') and '/runtime_binding/' not in relative
            if workflow_domain and node.type == 'constant' and text(node) in {
                    'Runtime', 'EventLoop', 'Event', 'FSMSession', 'FSMProtocol', 'TerminalDecision',
                    'WorkflowPhaseMachineBuilder', 'WorkflowTerminalPolicy', 'WorkflowEngineEnvironment'}:
                findings.append({'kind': 'workflow-selects-engine', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if workflow_domain and node.type == 'call':
                method = text(node.child_by_field_name('method'))
                args = node.child_by_field_name('arguments')
                if method in {'require', 'require_relative'} and args and 'state_machines' in text(args):
                    findings.append({'kind': 'workflow-selects-engine', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
            coordination = relative.startswith('lib/phronomy/multi_agent/') and '/runtime_binding/' not in relative
            if agent_domain or workflow_domain or coordination:
                if node.type == 'call':
                    method = text(node.child_by_field_name('method'))
                    receiver = text(node.child_by_field_name('receiver')).lstrip(':')
                    args = node.child_by_field_name('arguments')
                    first = args.named_children[0] if args and args.named_children else None
                    indirect = (text(first).lstrip(':').strip('\"\'')
                                if method in {'send', '__send__', 'public_send'} else '')
                    if receiver == 'Phronomy' and (method == 'configuration' or indirect == 'configuration'):
                        findings.append({'kind': 'domain-reads-application-configuration',
                                         'file': relative, 'line': node.start_point.row + 1,
                                         'call': text(node)})
                    if method in {'authorization_pool_size', 'authorization_queue_size'}:
                        findings.append({'kind': 'domain-selects-execution-pool-resources',
                                         'file': relative, 'line': node.start_point.row + 1,
                                         'call': text(node)})
                if node.type == 'constant' and text(node) == 'Configuration':
                    findings.append({'kind': 'domain-reads-application-configuration',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
            if coordination and node.type == 'constant' and text(node) == 'Tools':
                findings.append({'kind': 'coordination-selects-concrete-tool', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if coordination and node.type == 'constant' and text(node) in {
                    'Runtime', 'EventLoop', 'FSMSession', 'EngineEnvironment'}:
                findings.append({'kind': 'coordination-selects-engine', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            agent_progress = relative.startswith((
                'lib/phronomy/agent/execution/', 'lib/phronomy/agent/recovery/',
                'lib/phronomy/agent/lifecycle/', 'lib/phronomy/agent/tool_execution/')) or relative == 'lib/phronomy/agent/execution_environment.rb'
            if node.type == 'constant' and agent_progress and text(node) in {
                    'Runtime', 'EventLoop', 'FSMSession', 'PhaseMachineBuilder',
                    'EngineSessionBuilder', 'EngineEnvironment', 'ToolSessionBuilder', 'ToolInvocationSessionBuilder'}:
                findings.append({'kind': 'agent-progress-knows-engine', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if node.type == 'call' and agent_progress:
                method = text(node.child_by_field_name('method'))
                args = node.child_by_field_name('arguments')
                if method in {'require', 'require_relative'} and args and 'state_machines' in text(args):
                    findings.append({'kind': 'agent-progress-knows-engine', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
            if node.type == 'constant' and agent_progress and text(node) == 'ToolExecutor':
                findings.append({'kind': 'agent-selects-tool-implementation', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if node.type == 'constant':
                denied = ({'RubyLLM', 'Agent', 'MultiAgent', 'LLMAdapter', 'Runtime', 'Engine', 'ExecutionRehydrationRequiredError'} if tool_contract else set())
                if llm_contract:
                    denied |= {'RubyLLM', 'Agent', 'MultiAgent', 'Runtime', 'Engine', 'Execution', 'AsyncOperation'}
                if agent:
                    denied |= {'RubyLLM'}
                if text(node) in denied:
                    findings.append({'kind': 'llm-tool-contract-owner-leak', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
            if llm_contract and node.type == 'scope_resolution' and text(node).endswith('Tool::Base'):
                findings.append({'kind': 'llm-tool-contract-owner-leak', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if node.type == 'call':
                method = text(node.child_by_field_name('method'))
                args = node.child_by_field_name('arguments')
                first = args.named_children[0] if args and args.named_children else None
                indirect = (text(first).lstrip(':').strip('\"\'')
                            if method in {'send', '__send__', 'public_send'} else '')
                if generation and (method == '__invoke_async_with_event_sink'
                                   or indirect == '__invoke_async_with_event_sink'):
                    findings.append({'kind': 'generation-invokes-private-agent-operation',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
                if coordination and (method in {'__register_shutdown_participant', '__shutdown_participant'}
                                     or indirect in {'__register_shutdown_participant', '__shutdown_participant'}):
                    findings.append({'kind': 'coordination-selects-engine', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
                if relative in ADMISSION and (method in PARENT_CALLS or indirect in PARENT_CALLS):
                    findings.append({'kind': 'agent-interprets-parent-reservation',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
                if relative == 'lib/phronomy/multi_agent/team_coordinator.rb':
                    receiver = text(node.child_by_field_name('receiver'))
                    if ((receiver.endswith('agent_store') and (method in {'agents', 'journals', 'executions', 'handoff_states', 'participate'} or indirect in {'agents', 'journals', 'executions', 'handoff_states', 'participate'}))
                            or method == 'journal_position' or indirect == 'journal_position'):
                        findings.append({'kind': 'team-reads-agent-internals', 'file': relative,
                                         'line': node.start_point.row + 1, 'call': text(node)})
                if method in PRIVATE_CALLS or indirect in PRIVATE_CALLS:
                    findings.append({'kind': 'private-execution-control-leak',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
                if relative in CONSUMERS and method in {'deferred', 'complete', 'fail'}:
                    findings.append({'kind': 'consumer-settles-result', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
            if relative.startswith('lib/phronomy/agent/') and node.type == 'constant' and text(node) == 'MultiAgent':
                findings.append({'kind': 'agent-knows-coordination-domain', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if relative.startswith('lib/phronomy/multi_agent/') and '/persistence/' not in relative and relative != 'lib/phronomy/multi_agent/team_coordinator.rb':
                if node.type == 'scope_resolution' and text(node).startswith('Phronomy::Agent::') and any(
                        text(node).endswith('::' + name) for name in ('AgentExecution', 'ExecutionMetadata', 'ExactExecution', 'RecoverySupport', 'JournalRecord', 'ContextImporter')):
                    findings.append({'kind': 'coordination-reads-agent-internals', 'file': relative,
                                     'line': node.start_point.row + 1, 'call': text(node)})
                if node.type == 'call':
                    method = text(node.child_by_field_name('method'))
                    receiver = text(node.child_by_field_name('receiver'))
                    if (receiver.endswith(('agent_store', '.persistence')) and method in {'agents', 'executions', 'journals', 'participate'}) or method == '_phronomy_event_listener':
                        findings.append({'kind': 'coordination-reads-agent-internals', 'file': relative,
                                         'line': node.start_point.row + 1, 'call': text(node)})
            if relative in {'lib/phronomy/persistence/transaction.rb', 'lib/phronomy/persistence/persistence.rb'} and node.type == 'constant':
                if text(node) in {'Agent', 'MultiAgent', 'Workflow', 'Runtime', 'PersistenceComposition'}:
                    findings.append({'kind': 'transaction-knows-domain-or-composition',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
            if relative == 'lib/phronomy/multi_agent/team_coordinator.rb' and node.type == 'constant' and text(node) == 'ExecutionMetadata':
                findings.append({'kind': 'team-reads-agent-internals', 'file': relative,
                                 'line': node.start_point.row + 1, 'call': text(node)})
            if relative in {'lib/phronomy/agent/store.rb', 'lib/phronomy/agent/admission.rb',
                            'lib/phronomy/multi_agent/store.rb', 'lib/phronomy/multi_agent/reserved_child_admission.rb'}:
                if node.type == 'scope_resolution' and 'Persistence::' in text(node) and any(
                        part in text(node) for part in ('::Records', '::Admission', '::Reservation', '::Codec', '::StorageSchema', '::ExecutionRepository')):
                    findings.append({'kind': 'domain-selects-storage-implementation',
                                     'file': relative, 'line': node.start_point.row + 1,
                                     'call': text(node)})
            for child in node.named_children:
                walk(child)
        walk(root)
    return findings
