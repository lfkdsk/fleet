#!/usr/bin/env bash
# P20 shell "commander": echoes the user messages it was actually given back
# as `reply`, so a test can prove what reached the prompt and what came out.
python3 - "$0" <<'PY'
import json,re,sys,time
s=open(sys.argv[1]).read(); mode='__P20_MODE__'
def number(pattern): return int(re.search(pattern,s).group(1))
goal=number(r'"id": (\d+)')
rev=number(r'"revision": (\d+)')
through=number(r'"through_event_id": (\d+)')
# The prompt is a JSON document quoted inside this script's heredoc. Parse the
# LAST complete object rather than regexing fields out: user_messages bodies are
# user text and may contain anything, including things that look like fields.
dec=json.JSONDecoder()
best=None
for m in re.finditer(r'\{',s):
    try: v,end=dec.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'protocol_version' in v and (best is None or end>best[0]):
        best=(end,v)
prompt=best[1] if best else {}
msgs=prompt.get('user_messages') or []
if mode == 'slow': time.sleep(2)
def candidate(key, command='printf worker'):
    return {'channel':'shell','title':('worker '+key)[:40],
            'problem':command,'evidence':'ledger evidence',
            'expected_artifact':'worker output',
            'verification':'read the worker out.md',
            'dedup_key':key,'scope':'isolated test home'}
tasks=[]
if mode in ('propose','noapply'): tasks=[candidate('p20-alpha')]
out={'goal_id':goal,'based_on_plan_revision':rev,'through_event_id':through,
     'proposed_tasks':tasks,'decisions':[],
     'next_wake':{'reason':'review_ready'}}
if mode != 'noreply':
    # Name every message id and body the prompt carried: the assertion is about
    # what the model SAW, which a fixed string could not distinguish.
    out['reply']=('saw ' + str(len(msgs)) + ': '
                  + ' | '.join(f"{m['id']}:{m['body']}" for m in msgs))
print('free form before the final object')
print(json.dumps(out,ensure_ascii=False))
PY
