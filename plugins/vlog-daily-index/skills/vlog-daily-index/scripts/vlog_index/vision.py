"""Validate a current-session native tool snapshot; never call a model API."""
from __future__ import annotations
import copy
import re

FAMILIES = ('luna', 'haiku', 'deepseek')
PARAMETERS = ('model', 'reasoning_effort', 'fork_turns', 'subagent_type')
LUNA_EFFORT = 'medium'
SCHEMA = 'native_vision_capabilities_v1'
# Declared roles that name a model family instead of an agent. config.model_roles keeps Codex's
# historical 'Luna' literal, so resolve it here instead of rewriting writerspace state.
ROLE_FAMILIES = {'Luna': 'luna'}
# Native tools may accept a short alias for a model instead of its full identity.
NATIVE_ALIASES = {'haiku': 'haiku'}


def _family(model_id):
    if model_id == 'gpt-6-luna': return 'luna'
    if re.fullmatch(r'(?:anthropic/)?claude-(?:haiku-[0-9]+(?:[.-][0-9]+)*(?:-latest)?|[0-9]+(?:[.-][0-9]+)*-haiku(?:-[0-9]+|-latest)?)', model_id): return 'haiku'
    if re.fullmatch(r'(?:deepseek/)?deepseek-[a-z0-9][a-z0-9.-]*', model_id): return 'deepseek'
    return None


def _bare(model_id):
    return model_id.removeprefix('anthropic/').removeprefix('deepseek/')


def _model_reason(item, parameters):
    """First reason an advertised model cannot serve pure visual claims, else None."""
    family = _family(item['id'])
    if family != item.get('family'): return 'model ID/family is outside the Luna/Haiku/DeepSeek allowlist'
    if item.get('image_input') is not True: return 'native image input is not explicitly supported'
    if item.get('native_model') not in parameters.get('model', []): return 'model is not selectable through the native model parameter'
    if item['native_model'] != NATIVE_ALIASES.get(family) and (
            _family(item['native_model']) != family or _bare(item['native_model']) != _bare(item['id'])):
        return 'native model parameter does not match the advertised model identity'
    efforts = item.get('reasoning_efforts')
    if efforts is not None and (not isinstance(efforts, list) or not efforts or any(
            not isinstance(v, str) or v not in parameters.get('reasoning_effort', []) for v in efforts)
            or len(efforts) != len(set(efforts))):
        return 'model reasoning values are not supported by the native tool'
    if family == 'luna' and (efforts is None or LUNA_EFFORT not in efforts):
        return 'Luna requires a controllable medium reasoning effort'
    default = item.get('default_reasoning_effort')
    if default is not None and (efforts is None or default not in efforts):
        return 'default reasoning effort is not supported by this model'
    return None


def _agent_reason(item, parameters):
    """First reason an advertised agent cannot serve pure visual claims, else None."""
    if item.get('image_input') is not True: return 'native image input is not explicitly supported'
    if item['id'] not in parameters.get('subagent_type', []): return 'agent is not selectable through the native subagent_type parameter'
    if item.get('native_model') is not None or item.get('reasoning_efforts') is not None:
        return 'agent-routed targets own model and effort in agent frontmatter'
    return None


def role_family(vision_role):
    return ROLE_FAMILIES.get(vision_role)


def _role_is_agent(vision_role):
    """A declared role names an agent only when it is not one of the family-mapped literals."""
    return vision_role is not None and role_family(vision_role) is None


def _reason(item, parameters, vision_role):
    """A target is either an allowlisted model or the run's declared vision agent; never both.

    A family-mapped role such as Codex's 'Luna' literal never satisfies an agent target, so it
    cannot smuggle a model past the family rules that enforce Luna's medium effort.
    """
    if _family(item['id']) is not None: return _model_reason(item, parameters)
    if _role_is_agent(vision_role) and item['id'] == vision_role: return _agent_reason(item, parameters)
    return 'target is neither an allowed model family nor the declared vision agent'


def _declared(item, vision_role):
    """A declared role that names a family is satisfied by any model of that family."""
    if not _role_is_agent(vision_role): return role_family(vision_role) is not None and _family(item['id']) == role_family(vision_role)
    return item['id'] == vision_role


def _snapshot(capabilities):
    """Validate snapshot shape once; return (source, parameters, models)."""
    if not isinstance(capabilities, dict) or capabilities.get('schema') != SCHEMA:
        raise ValueError('New visual claims require current-session --native-capabilities (' + SCHEMA + ')')
    source = capabilities.get('source')
    if not isinstance(source, dict) or source.get('kind') != 'current_session_native_tool' or any(
            not isinstance(source.get(k), str) or not source[k].strip() for k in ('session_id', 'tool', 'evidence')):
        raise ValueError('Native capability source needs current session_id, tool and tool-schema/image-capability evidence')
    parameters = capabilities.get('parameters')
    if not isinstance(parameters, dict) or not any(parameters.get(k) for k in ('model', 'subagent_type')):
        raise ValueError('Native capability snapshot must expose a controllable model or subagent_type parameter')
    for name, values in parameters.items():
        if name not in PARAMETERS or not isinstance(values, list) or not values or any(
                not isinstance(v, str) or not v for v in values) or len(values) != len(set(values)):
            raise ValueError('Invalid native parameter values: ' + str(name))
    models = capabilities.get('models')
    if not isinstance(models, list) or not models: raise ValueError('Native capability snapshot needs advertised models')
    if any(not isinstance(item, dict) or not isinstance(item.get('id'), str) for item in models):
        raise ValueError('Advertised model IDs must be unique strings')
    ids = [item['id'] for item in models]
    if len(ids) != len(set(ids)): raise ValueError('Advertised model IDs must be unique strings')
    return source, parameters, models


def dispatch_contract(capabilities, model=None, reasoning_effort=None, vision_role=None):
    """The harness supplies tool evidence, not an independently verified receipt.

    Selection follows the explicit model, the run's declared vision role, the session
    preference (only when no role is declared), then the advertised order. Explicit
    requests and declared roles fail closed instead of selecting another provider,
    model or route.
    """
    source, parameters, models = _snapshot(capabilities)
    eligible, rejected = [], []
    for item in models:
        reason = _reason(item, parameters, vision_role)
        if reason: rejected.append({'model': item['id'], 'reason': reason})
        else: eligible.append(item)
    preferred = capabilities.get('preferred_model')
    if not eligible:
        raise ValueError('No eligible native visual route for ' +
                         str(model or vision_role or preferred or 'advertised models') + ': ' + str(rejected))
    # preferred_model is a session default, not a user choice, so a declared role outranks it.
    requested = model if model is not None else (preferred if vision_role is None else None)
    if requested is not None:
        selected = next((item for item in eligible if item['id'] == requested), None)
        if selected is None: raise ValueError('Requested native visual route is not eligible: ' + str(requested) + ': ' + str(rejected))
    elif vision_role is None:
        selected = eligible[0]
    else:
        # A declared role that cannot serve pure visual claims fails instead of silently
        # dispatching a different model or agent than the run asked for.
        if not any(_declared(item, vision_role) for item in models):
            raise ValueError('Declared vision role is not advertised in the native capability snapshot: ' + str(vision_role))
        selected = next((item for item in eligible if _declared(item, vision_role)), None)
        if selected is None:
            raise ValueError('Declared vision role is not eligible for pure visual claims: ' + str(vision_role) + ': ' + str(rejected))
    family = _family(selected['id'])
    effort = None
    if family is None:
        if reasoning_effort is not None:
            raise ValueError('Agent-routed visual dispatch takes model and effort from agent frontmatter; omit --reasoning-effort')
        native = {'subagent_type': selected['id']}
    else:
        effort = reasoning_effort if reasoning_effort is not None else (
            LUNA_EFFORT if family == 'luna' else selected.get('default_reasoning_effort'))
        if family == 'luna' and effort != LUNA_EFFORT: raise ValueError('Luna pure visual claims require medium reasoning effort')
        supported = selected.get('reasoning_efforts') or []
        if effort is not None and effort not in supported:
            raise ValueError('Requested reasoning effort is not supported by this native model')
        native = {'model': selected['native_model']}
        if effort is not None: native['reasoning_effort'] = effort
    if 'none' in parameters.get('fork_turns', []): native['fork_turns'] = 'none'
    if model is not None: reason = 'explicit_model'
    elif requested is not None: reason = 'session_preferred_model'
    elif vision_role is not None: reason = 'declared_vision_role'
    else: reason = 'first_eligible_advertised_model'
    return {'schema': 'native_vision_dispatch_v2', 'stage': 'pure_visual',
            'route': 'agent' if family is None else 'model',
            'requested_model': selected['id'], 'requested_reasoning_effort': effort,
            'family': family, 'vision_role': vision_role, 'native_tool': source['tool'],
            'native_spawn_parameters': native, 'selection_reason': reason,
            'capability_snapshot': copy.deepcopy(capabilities),
            'capability_verification': 'harness_supplied_snapshot', 'runtime_verification': 'unverified'}
