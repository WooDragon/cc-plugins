"""Validate a current-session native tool snapshot; never call a model API."""
from __future__ import annotations
import copy
import re

FAMILIES = ('luna', 'haiku', 'deepseek')


def _family(model_id):
    if model_id == 'gpt-6-luna': return 'luna'
    if re.fullmatch(r'(?:anthropic/)?claude-(?:haiku-[0-9]+(?:[.-][0-9]+)*(?:-latest)?|[0-9]+(?:[.-][0-9]+)*-haiku(?:-[0-9]+|-latest)?)', model_id): return 'haiku'
    if re.fullmatch(r'(?:deepseek/)?deepseek-[a-z0-9][a-z0-9.-]*', model_id): return 'deepseek'
    return None


def dispatch_contract(capabilities, model=None, reasoning_effort=None):
    """The harness supplies tool evidence, not an independently verified receipt.

    Default selection follows preferred_model, then the advertised model order.
    Explicit requests fail closed instead of selecting another provider/model.
    """
    if not isinstance(capabilities, dict) or capabilities.get('schema') != 'native_vision_capabilities_v1':
        raise ValueError('New visual claims require current-session --native-capabilities (native_vision_capabilities_v1)')
    source = capabilities.get('source', {})
    if not isinstance(source, dict) or source.get('kind') != 'current_session_native_tool' or any(
            not isinstance(source.get(k), str) or not source[k].strip() for k in ('session_id', 'tool', 'evidence')):
        raise ValueError('Native capability source needs current session_id, tool and tool-schema/image-capability evidence')
    parameters = capabilities.get('parameters', {})
    if not isinstance(parameters, dict) or not isinstance(parameters.get('model'), list) or not parameters['model']:
        raise ValueError('Native capability snapshot must expose controllable model parameter values')
    for name, values in parameters.items():
        if name not in ('model', 'reasoning_effort', 'fork_turns') or not isinstance(values, list) or not values or any(
                not isinstance(v, str) or not v for v in values) or len(values) != len(set(values)):
            raise ValueError('Invalid native parameter values: ' + str(name))
    models = capabilities.get('models')
    if not isinstance(models, list) or not models:
        raise ValueError('Native capability snapshot needs advertised models')
    eligible = []; rejected = []; seen = set()
    for item in models:
        if not isinstance(item, dict) or not isinstance(item.get('id'), str) or item['id'] in seen:
            raise ValueError('Advertised model IDs must be unique strings')
        seen.add(item['id']); family = _family(item['id'])
        reason = None
        if family is None or family != item.get('family'): reason = 'model ID/family is outside the Luna/Haiku/DeepSeek allowlist'
        elif item.get('image_input') is not True: reason = 'native image input is not explicitly supported'
        elif item.get('native_model') not in parameters['model']: reason = 'model is not selectable through the native model parameter'
        elif (item['native_model'] != {'haiku': 'haiku'}.get(family) and
              (_family(item['native_model']) != family or
               item['native_model'].removeprefix('anthropic/').removeprefix('deepseek/') != item['id'].removeprefix('anthropic/').removeprefix('deepseek/'))):
            reason = 'native model parameter does not match the advertised model identity'
        efforts = item.get('reasoning_efforts')
        if efforts is not None and (not isinstance(efforts, list) or not efforts or any(
                not isinstance(v, str) or v not in parameters.get('reasoning_effort', []) for v in efforts)
                or len(efforts) != len(set(efforts))):
            reason = 'model reasoning values are not supported by the native tool'
        if family == 'luna' and (efforts is None or 'medium' not in efforts):
            reason = 'Luna requires a controllable medium reasoning effort'
        default = item.get('default_reasoning_effort')
        if default is not None and (efforts is None or default not in efforts):
            reason = 'default reasoning effort is not supported by this model'
        if reason: rejected.append({'model': item['id'], 'reason': reason})
        else: eligible.append(item)
    preferred = capabilities.get('preferred_model')
    requested = model if model is not None else preferred
    selected = next((item for item in eligible if item['id'] == requested), None) if requested is not None else next(iter(eligible), None)
    if selected is None:
        raise ValueError('No eligible native visual route for ' + str(requested or 'advertised models') + ': ' + str(rejected))
    if selected['family'] == 'luna':
        effort = reasoning_effort if reasoning_effort is not None else 'medium'
        if effort != 'medium': raise ValueError('Luna pure visual claims require medium reasoning effort')
    else:
        effort = reasoning_effort if reasoning_effort is not None else selected.get('default_reasoning_effort')
    if effort is not None and effort not in selected.get('reasoning_efforts', []):
        raise ValueError('Requested reasoning effort is not supported by this native model')
    native = {'model': selected['native_model']}
    if effort is not None: native['reasoning_effort'] = effort
    if 'none' in parameters.get('fork_turns', []): native['fork_turns'] = 'none'
    return {'schema': 'native_vision_dispatch_v2', 'stage': 'pure_visual',
            'requested_model': selected['id'], 'requested_reasoning_effort': effort,
            'family': selected['family'], 'native_tool': source['tool'],
            'native_spawn_parameters': native,
            'selection_reason': 'explicit_model' if model is not None else 'session_preferred_model' if preferred is not None else 'first_eligible_advertised_model',
            'capability_snapshot': copy.deepcopy(capabilities),
            'capability_verification': 'harness_supplied_snapshot', 'runtime_verification': 'unverified'}
