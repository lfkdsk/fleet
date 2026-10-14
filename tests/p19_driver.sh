#!/usr/bin/env bash
python3 - "$0" <<'PY'
import json,re,sys
import os
import time
s=open(sys.argv[1]).read(); mode='__P19_MODE__'
if mode == 'slow': time.sleep(1)
def number(pattern): return int(re.search(pattern,s).group(1))
goal=number(r'"id": (\d+)')
rev=number(r'"revision": (\d+)')
through=number(r'"through_event_id": (\d+)')
def candidate(key, command='printf worker', channel='shell'):
    return {'channel':channel,'title':('worker '+key)[:40],
            'problem':command,'evidence':'ledger evidence',
            'expected_artifact':'worker output',
            'verification':'read the worker out.md',
            'dedup_key':key,'scope':'isolated test home'}
if mode == 'bad':
    print('not json'); raise SystemExit
if mode == 'two': tasks=[candidate('alpha'),candidate('beta')]
elif mode == 'three': tasks=[candidate('alpha'),candidate('beta'),candidate('gamma')]
elif mode == 'one': tasks=[candidate('same')]
elif mode == 'pwdtwo':
    tasks=[candidate('pwd-alpha','pwd'),candidate('pwd-beta','pwd')]
elif mode == 'commit':
    tasks=[candidate('commit-upstream',
        "printf 'upstream-only\n' > upstream.txt; git add upstream.txt; "
        "git -c user.email=p19@example.test -c user.name=p19 commit -qm upstream")]
elif mode == 'base':
    item=candidate('base-'+os.environ['FLEET_TEST_BASE_TASK'],
                   "test -f upstream.txt; git rev-parse HEAD")
    item['base_task']=int(os.environ['FLEET_TEST_BASE_TASK'])
    tasks=[item]
elif mode == 'slowworker': tasks=[candidate('slow-worker','sleep 2; pwd')]
elif mode == 'chain':
    rounds=int(re.search(r'"rounds_used": (\d+)',s).group(1))
    tasks=[candidate('chain-'+str(rounds), 'printf chain-'+str(rounds))]
elif mode == 'review-candidates':
    review_of=int(os.environ['FLEET_TEST_REVIEW_OF'])
    same=candidate('review-same', channel='review-gpt')
    same['review_of']=review_of
    other=candidate('review-other', channel='review-claude')
    other['review_of']=review_of
    tasks=[same,other]
elif mode == 'review-same':
    review_of=int(os.environ['FLEET_TEST_REVIEW_OF'])
    item=candidate('review-same', channel='review-gpt')
    item['review_of']=review_of
    tasks=[item]
elif mode == 'probe-failed':
    tasks=[candidate('probe-failed', channel='review-claude')]
elif mode == 'longtitle':
    # 71-char English and 48-char Chinese titles: both over the 40-char
    # Python-len() cap, the Chinese one draws 96 columns so a width-based
    # clip would mangle it differently.
    en=candidate('long-en'); en['title']='E'*71
    cn=candidate('long-cn'); cn['title']='超长标题'*12
    tasks=[en,cn]
elif mode == 'longtitle-bad':
    # Overlong title plus a genuinely invalid field: the title relaxation
    # must not save the proposal.
    bad=candidate('long-bad'); bad['title']='L'*50; bad['problem']='   '
    tasks=[bad]
else: tasks=[]
wake='review_ready' if mode in ('review','empty','slow') else 'waiting_for_tasks'
print('free form before the final object')
print(json.dumps({'goal_id':goal,'based_on_plan_revision':rev,
 'through_event_id':through,'proposed_tasks':tasks,'decisions':[],
 'next_wake':{'reason':wake}}))
PY

