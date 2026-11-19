#!/usr/bin/python3
"""Deterministic JSONL peer for CodexService's stream/cancellation/privacy checks."""
import json
import os
import sys
import threading
import time

lock = threading.Lock()
current_turn = None
counter = 0
startup_change_fired = False
startup_auth_mode = 'chatgpt'
initialized_received = False
startup_counts = {'initializes': 0, 'initializedNotifications': 0,
                  'accountReads': 0, 'configReads': 0, 'modelLists': 0, 'changes': 0}

def quota_payload(used=18, weekly_used=46):
    # Keep reset dates ahead of the test clock without assuming a particular timezone.
    reset = int(time.time()) + 3600
    bucket = {'limitId': 'codex',
              'primary': {'usedPercent': used, 'windowDurationMins': 300, 'resetsAt': reset},
              'secondary': {'usedPercent': weekly_used, 'windowDurationMins': 10080,
                            'resetsAt': reset + 604800}}
    return {'rateLimits': bucket, 'rateLimitsByLimitId': {'codex': bucket}}

def quota_mode():
    # Each service process has its own isolated OnlineWorkspace. Tests control only
    # this synthetic peer; no user's account or authentication files are involved.
    try:
        with open('quota-mode.txt', encoding='utf-8') as source:
            return source.read().strip()
    except FileNotFoundError:
        return 'initial'

def startup_mode():
    try:
        with open('startup-mode.txt', encoding='utf-8') as source:
            return source.read().strip()
    except FileNotFoundError:
        return ''

def write_startup_audit():
    # Inspect only synthetic protocol counts, never account identifiers.
    if startup_mode():
        with open('startup-audit.json', 'w', encoding='utf-8') as destination:
            json.dump(startup_counts, destination)

def maybe_change_startup_account(stage):
    global startup_change_fired, startup_auth_mode
    mode = startup_mode()
    if startup_change_fired or mode not in (stage + '-logout', stage + '-change'):
        return
    startup_change_fired = True
    startup_auth_mode = None if mode.endswith('-logout') else 'chatgpt'
    startup_counts['changes'] += 1
    write_startup_audit()
    # Emit before completing the pending RPC. The response is an old-account
    # reading and must not revive readiness after this notification.
    notification('account/updated', {'authMode': startup_auth_mode})

def emit(value, fragmented=False):
    data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    with lock:
        if fragmented:
            # Split UTF-8 codepoints and JSON lines across reads.
            for start in range(0, len(data), 7):
                os.write(1, data[start:start + 7])
                time.sleep(.001)
        else:
            os.write(1, data)

def result(i, value): emit({'id': i, 'result': value})
def notification(method, params): emit({'method': method, 'params': params})
def finish(thread, turn, text, delayed=False):
    global current_turn
    if delayed: time.sleep(3)
    if current_turn != turn: return
    notification('item/started', {'threadId': thread, 'turnId': turn, 'item': {'id': 'assistant', 'type': 'agentMessage'}})
    emit({'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': turn, 'itemId': 'assistant', 'delta': text}}, fragmented=True)
    notification('item/completed', {'threadId': thread, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'assistant', 'text': text}})
    notification('turn/completed', {'threadId': thread, 'turn': {'id': turn, 'status': 'completed'}})

for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method'); i = request.get('id'); params = request.get('params', {})
    if method == 'initialize':
        startup_counts['initializes'] += 1
        write_startup_audit()
        maybe_change_startup_account('initialize')
        result(i, {'userAgent': 'stashcat-test'})
    elif method == 'initialized':
        initialized_received = True
        startup_counts['initializedNotifications'] += 1
        write_startup_audit()
    elif method == 'account/read':
        assert initialized_received, 'A reused connection must finish its initialize/initialized handshake'
        startup_counts['accountReads'] += 1
        write_startup_audit()
        result(i, {'account': {'type': 'chatgpt'} if startup_auth_mode else None, 'requiresOpenaiAuth': True})
    elif method == 'account/rateLimits/read':
        mode = quota_mode()
        if startup_change_fired and startup_auth_mode:
            result(i, quota_payload(7, 11))
        elif mode == 'unsupported':
            emit({'id': i, 'error': {'code': -32601, 'message': 'Method not found'}})
        elif mode == 'failure':
            emit({'id': i, 'error': {'code': -32000, 'message': 'Temporary quota lookup failure'}})
        elif mode == 'notification':
            # There is deliberately no threadId, turnId or active chat turn. The
            # notification is newer than the RPC reading that follows it.
            notification('account/rateLimits/updated', quota_payload(21, 47))
            result(i, quota_payload())
        elif mode == 'recovered': result(i, quota_payload(30, 45))
        elif mode == 'after-turn': result(i, quota_payload(35, 48))
        else: result(i, quota_payload())
    elif method == 'config/read':
        startup_counts['configReads'] += 1
        write_startup_audit()
        maybe_change_startup_account('config')
        result(i, {'config': {'mcp_servers': {'test.server': {'enabled': True}}}})
    elif method == 'model/list':
        startup_counts['modelLists'] += 1
        write_startup_audit()
        display_name = 'Changed Account Model' if startup_change_fired and startup_auth_mode else 'Mock Model'
        maybe_change_startup_account('model')
        result(i, {'data': [{'model': 'mock-model', 'displayName': display_name, 'isDefault': True, 'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}]}]})
    elif method == 'thread/start':
        assert params['ephemeral'] is True
        assert params['sandbox'] == 'read-only'
        assert params['approvalPolicy'] == 'never'
        assert params['config']['mcp_servers']['test.server']['enabled'] is False
        assert os.path.basename(params['cwd']) == 'OnlineWorkspace'
        counter += 1
        result(i, {'thread': {'id': 'thread-' + str(counter), 'ephemeral': True}})
    elif method == 'turn/start':
        thread = params['threadId']; current_turn = 'turn-' + str(counter)
        assert params['sandboxPolicy']['type'] == 'readOnly'
        assert params['sandboxPolicy']['networkAccess'] is False
        text = params['input'][0]['text']
        result(i, {'turn': {'id': current_turn, 'status': 'inProgress'}})
        notification('turn/started', {'threadId': thread, 'turn': {'id': current_turn}})
        if 'TEST_IMAGE' in text:
            images = [item for item in params['input'] if item.get('type') == 'localImage']
            assert len(images) == 1 and os.path.isfile(images[0]['path'])
            assert 'localImage' not in text
            threading.Thread(target=finish, args=(thread, current_turn, '图片输入已收到。'), daemon=True).start()
        elif 'TEST_APPROVAL' in text:
            emit({'id': 'approval-1', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': thread, 'turnId': current_turn}})
        elif 'TEST_FAIL' in text:
            notification('turn/completed', {'threadId': thread, 'turn': {'id': current_turn, 'status': 'failed', 'error': {'message': '401 Unauthorized'}}})
        else:
            threading.Thread(target=finish, args=(thread, current_turn, '连接成功。x² 的导数是 2x。', 'TEST_WAIT' in text), daemon=True).start()
    elif method == 'turn/interrupt':
        current_turn = None
        result(i, {})
        notification('turn/completed', {'threadId': params['threadId'], 'turn': {'id': params['turnId'], 'status': 'interrupted'}})
    elif method is None:
        assert request.get('result', {}).get('decision') == 'decline'
    else: emit({'id': i, 'error': {'code': -32601, 'message': 'Unsupported test method'}})
