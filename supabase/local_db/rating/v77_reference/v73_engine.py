"""Independent V7.3 experimental engine, not app code. Deterministic replay."""
import math, statistics, random, json, csv
from collections import deque
from pathlib import Path
from v72_corrected import P,W,MG,MA,clip,vote,let as old_let,defence as old_def,reflex as old_ref,apr as old_apr,dis
OUT=Path('/mnt/data/min91audit')

def resenha(votes, player_id, attended=True):
    if not attended:return None
    if votes is None:return None
    valid={str(k):bool(v) for k,v in votes.items() if str(k)!=str(player_id) and v is not None}
    if len(valid)<3:return None # conservative small-sample rule: no majority with <=2 voters
    yes=sum(valid.values())
    return yes>=2 and yes>len(valid)/2

def rating_raw(hist, pos, env, prior=None, prior_strength=0):
    # historical sports rates; no missing => retain last valid at caller
    n=len(hist); qs=[vote(x['q']) for x in hist if x.get('q') is not None]
    q=statistics.mean(qs) if qs else (prior.get('q',70) if prior else 70)
    out={}
    for attr in ('DEF','SECOND','APR'):
        if attr=='DEF':
            vals=[x['conceded'] for x in hist if x.get('conceded') is not None]
            raw=old_def(vals,q,env) if vals else None
        elif attr=='SECOND':
            if pos=='GOL':
                vals=[x['saves'] for x in hist if x.get('saves') is not None]
                raw=old_ref(vals,q) if vals else None
            else:
                vals=[x for x in hist if x.get('goals') is not None and x.get('assists') is not None]
                raw=old_let([x['goals'] for x in vals],[x['assists'] for x in vals],pos,q) if vals else None
        else:
            vals=[x['result'] for x in hist if x.get('result') is not None]
            raw=old_apr(vals,q) if vals else None
        if prior and prior_strength and raw is not None:
            # previous-season evidence contributes a bounded prior, not a 50% reduction of the displayed attribute
            w=prior_strength/(prior_strength+len(hist))
            raw=w*prior.get(attr,raw)+(1-w)*raw
        out[attr]=raw
    return out,q

class MovingState:
    def __init__(self, initial=None):
        self.published=initial;self.last_raw=None;self.recent=deque(maxlen=10)
    def update(self,raw):
        if raw is None:return self.published
        if self.published is None:self.published=raw;self.last_raw=raw;self.recent.append(0);return raw
        delta=raw-self.last_raw if self.last_raw is not None else 0
        self.recent.append(delta)
        self.last_raw=raw
        if raw>=self.published:self.published=raw;return raw
        # actual 10-match rolling trend: worsening share and total deterioration
        downs=sum(d<-.00001 for d in self.recent)
        decline=max(0,-sum(self.recent))
        severity=min(1,decline/12)
        alpha=.30+.35*(downs/10)+.20*severity
        self.published=clip(self.published+alpha*(raw-self.published))
        return self.published

def evaluate(events,pos,env=3,previous=None):
    prior=previous or {}
    # 50% of 10-game reference evidence, decays as new games accrue
    strength=5 if previous else 0
    states={a:MovingState(prior.get(a)) for a in ('DEF','SECOND','APR')}
    history=[];cards=[];attendance=[];after=[];last_res=prior.get('RES',70);last_dis=prior.get('DIS',70)
    output=[]
    for idx,e in enumerate(events,1):
        if not e.get('played',True):
            attendance.append(False)
        else:
            history.append(e);attendance.append(True)
            cards.append((e.get('yellow',0),e.get('red',0)))
            after.append(resenha(e.get('resenha_votes'),e.get('id','self'),True))
        raw,q=rating_raw(history,pos,env,prior,strength)
        attrs={a:(states[a].published if not e.get('played',True) else states[a].update(raw[a])) for a in states}
        # RES: attendance includes missed rounds; after excludes unknown confirmations
        present=(sum(attendance)+2)/(len(attendance)+4)
        known=[x for x in after if x is not None]
        after_rate=(sum(known)+2)/(len(known)+4) if known else None
        if after_rate is None and not prior and not known:
            after_rate=.5 # neutral prior, no negative inference from missing
        if after_rate is not None:
            last_res=clip(.95*(.6*(40+59*present)+.4*(40+59*after_rate))+.05*q)
        if cards:last_dis=dis(cards)
        attrs['RES']=last_res;attrs['DIS']=last_dis
        if any(attrs[k] is None for k in ('DEF','SECOND','APR')):
            # missing source keeps previous value, or neutral for a player with no history
            for k in ('DEF','SECOND','APR'):
                if attrs[k] is None:attrs[k]=prior.get(k,70)
        ovr=sum(a*w for a,w in zip([attrs['DEF'],attrs['SECOND'],attrs['APR'],attrs['RES'],attrs['DIS']],W[pos]))
        output.append({'round':idx,'played_games':len(history),'ovr':ovr,**attrs})
    return output

def mk(q=8,goals=0,assists=0,conceded=3,saves=3,result=1/3,yellow=0,red=0,played=True,resenha_votes=None):
    return dict(q=q,goals=goals,assists=assists,conceded=conceded,saves=saves,result=result,yellow=yellow,red=red,played=played,resenha_votes=resenha_votes,id='self')

def validations():
    checks={}
    checks['10_goals_10_games_LET_gt_90']=evaluate([mk(q=9,goals=1) for _ in range(10)],'ATA')[-1]['SECOND']>90
    checks['missing_saves_preserved']=abs(evaluate([mk(saves=5)]*5+[mk(saves=None)],'GOL')[-1]['SECOND']-evaluate([mk(saves=5)]*5,'GOL')[-1]['SECOND'])<1e-9
    checks['missing_not_zero']=evaluate([mk(saves=5)]*5+[mk(saves=0)],'GOL')[-1]['SECOND']<evaluate([mk(saves=5)]*5,'GOL')[-1]['SECOND']
    checks['resenha_self_excluded']=resenha({'self':True,'a':False,'b':False,'c':True},'self') is False
    checks['resenha_majority']=resenha({'a':True,'b':True,'c':False},'self') is True
    checks['resenha_no_majority']=resenha({'a':True,'b':True,'c':False,'d':False},'self') is False
    checks['resenha_insufficient_unknown']=resenha({'a':True,'b':True},'self') is None
    checks['resenha_missing_unknown']=resenha(None,'self') is None
    checks['cards_immediate']=evaluate([mk()]*5+[mk(yellow=1)],'ATA')[-1]['DIS']<evaluate([mk()]*6,'ATA')[-1]['DIS']
    checks['absence_sports_unchanged']=all(abs(evaluate([mk()]*5+[mk(played=False)],'ATA')[-1][a]-evaluate([mk()]*5,'ATA')[-1][a])<1e-9 for a in ('DEF','SECOND','APR'))
    checks['absence_RES_lower']=evaluate([mk()]*5+[mk(played=False)],'ATA')[-1]['RES']<evaluate([mk()]*5,'ATA')[-1]['RES']
    a=[mk(goals=1,q=9)]*10+[mk(goals=0,q=7)]*20
    path=evaluate(a,'ATA')
    checks['checkpoint_real_window']=len(MovingState().recent)==0 and MovingState().recent.maxlen==10
    checks['checkpoint_not_frozen']=path[-1]['SECOND']<path[9]['SECOND']
    checks['checkpoint_no_boundary_jump']=abs(path[20]['SECOND']-path[19]['SECOND'])<3
    checks['retroactive_replay_deterministic']=evaluate(a,'ATA')==evaluate(a,'ATA')
    changed=a.copy();changed[1]=mk(goals=0,q=9)
    checks['retroactive_change_recalculates']=evaluate(changed,'ATA')[-1]['SECOND']!=path[-1]['SECOND']
    prev=evaluate([mk(goals=1,q=9)]*10,'ATA')[-1]
    start=evaluate([mk(goals=0,q=7)]*5,'ATA',previous=prev)
    fresh=evaluate([mk(goals=0,q=7)]*5,'ATA')
    checks['season_carryover_effect']=start[-1]['SECOND']>fresh[-1]['SECOND']
    checks['season_carryover_not_halved']=start[0]['SECOND']>prev['SECOND']*.5
    checks['all_values_in_bounds']=all(40<=x[k]<=99 for x in path for k in ('DEF','SECOND','APR','RES','DIS','ovr'))
    return checks,path

def population(seed=91,groups=1000,rounds=25):
    rng=random.Random(seed);means={p:[] for p in P}; jumps=[]; count=0
    for g in range(groups):
        size=rng.randint(25,40);count+=size
        env=max(1.8,min(4.8,rng.gauss(3,.55)))
        for i in range(size):
            pos=P[i%7];skill=rng.gauss(0,.85)
            hist=[]; last=None
            for t in range(rounds):
                q=max(0,min(10,rng.gauss(7+.55*skill,.75)))
                def pois(lam):
                    n=0;prod=1;lim=math.exp(-lam)
                    while prod>lim:prod*=rng.random();n+=1
                    return n-1
                # 80% attendance; participation data only when played
                if rng.random()<.16:e=mk(played=False)
                else:
                    e=mk(q=q,goals=pois(MG.get(pos,.1)*math.exp(.4*skill)),assists=pois(MA.get(pos,.1)*math.exp(.4*skill)),conceded=pois(env*math.exp(-.16*skill)),saves=None if rng.random()<.07 else pois(3*math.exp(.25*skill)),result=rng.choice([0,1/3,1]),yellow=int(rng.random()<.10),red=int(rng.random()<.015),resenha_votes=None if rng.random()<.12 else {str(j):rng.random()<.65 for j in range(5)})
                hist.append(e)
            seq=evaluate(hist,pos,env)
            means[pos].append(seq[-1]['ovr'])
            jumps.extend(seq[t]['ovr']-seq[t-1]['ovr'] for t in range(5,len(seq)))
    m={p:round(statistics.mean(means[p]),3) for p in P}
    return {'groups':groups,'players':count,'rounds':rounds,'participations_slots':count*rounds,'mean_ovr':m,'spread':round(max(m.values())-min(m.values()),3),'max_rise':round(max(jumps),3),'max_fall':round(min(jumps),3),'p99_rise':round(sorted(jumps)[int(.99*(len(jumps)-1))],3)}

if __name__=='__main__':
    checks,path=validations()
    print('CHECKS',sum(checks.values()),len(checks),flush=True)
    stats=population(groups=100,rounds=20)
    result={'checks':checks,'passed':sum(checks.values()),'total':len(checks),'population':stats}
    (OUT/'v73_results.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
    with (OUT/'v73_scenarios.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=path[0].keys());w.writeheader();w.writerows(path)
    print(json.dumps(result,ensure_ascii=False),flush=True)
