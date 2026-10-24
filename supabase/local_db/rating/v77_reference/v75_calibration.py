"""V7.5 diagnostic: coherent matches, zero change to attribute scoring functions.
Compare static V7.2 positional references to actual opportunities in the shared-match simulator.
Recalibration changes reference inputs only, not OVR weights, score curves or checkpoints.
"""
import numpy as np, json, math
from pathlib import Path
from v72_corrected import P,W,MG,MA,clip,vote,let as calc_let,defence,reflex,apr
OUT=Path(__file__).parent

def simulate(seed=91,groups=1000,rounds=20, fixed_refs=None, fixed_keeper=None, save=True):
 rng=np.random.default_rng(seed); all_rows=[]; group_data=[]; participants=0; games=0; players=0
 for group in range(groups):
  size=int(rng.integers(25,41));players+=size
  positions=[P[i%7] for i in range(size)];skill=rng.normal(0,.8,size)
  n=np.zeros(size,int);g=np.zeros(size);a=np.zeros(size);c=np.zeros(size);s=np.zeros(size);sn=np.zeros(size);r=np.zeros(size);q=np.zeros(size)
  for t in range(rounds):
   attendees=np.flatnonzero(rng.random(size)<.84)
   if len(attendees)<10:continue
   rng.shuffle(attendees);active=attendees[:min(len(attendees)//2*2,20)];half=len(active)//2
   if half<5:continue
   teams=(active[:half],active[half:]);ga=int(rng.poisson(2.8));gb=int(rng.poisson(2.8))
   games+=1;participants+=len(active)
   for team,opp,scored,against in ((teams[0],teams[1],ga,gb),(teams[1],teams[0],gb,ga)):
    weights=np.array([max(.01,MG.get(positions[i],.01))*np.exp(.35*skill[i]) for i in team]);weights/=weights.sum()
    for _ in range(scored):
     scorer=int(rng.choice(team,p=weights));g[scorer]+=1
     if rng.random()<.67:
      helper=int(rng.choice(team));
      if helper!=scorer:a[helper]+=1
    c[team]+=against;r[team]+=1 if scored>against else (1/3 if scored==against else 0)
    for i in team:
     if positions[i]=='GOL':
      chances=against+int(rng.poisson(2.5));s[i]+=int(rng.binomial(chances,.45));sn[i]+=1
    q[team]+=np.clip(rng.normal(7+.5*skill[team],.7),0,10)
   n[active]+=1
  for i,p in enumerate(positions):
   if n[i]<5:continue
   all_rows.append((p,n[i],g[i],a[i],c[i],s[i],sn[i],r[i],q[i],group))
  group_data.append(group)
 # Diagnostics: actual expected goals / assists per appearance and keeper saves
 stats={}; refs={}
 for p in P:
  rows=[x for x in all_rows if x[0]==p];total=sum(x[1] for x in rows)
  goals=sum(x[2] for x in rows)/total;assists=sum(x[3] for x in rows)/total
  saves=sum(x[5] for x in rows)/max(1,sum(x[6] for x in rows))
  stats[p]={'players':len(rows),'goal_rate':round(goals,4),'assist_rate':round(assists,4),'save_rate':round(saves,4)}
  if p!='GOL':refs[p]=(max(.03,goals),max(.03,assists))
 # Calculate counterfactual: positional references corrected to actual generated opportunities.
 # The scorer function itself stays exactly the same, only its mu inputs change.
 import v72_corrected as old
 orig_g,orig_a=old.MG.copy(),old.MA.copy()
 def keeper_reflex(d, n, q, reference):
  z=(d-reference)/2
  stat=clip(75+(24 if z>=0 else 25)*math.tanh(1.4*z))
  return clip(.75*(70+n/(n+3)*(stat-70))+.25*q)
 def evaluate_rows(calibrated, keeper_ref=3):
  if calibrated:
   for p,(x,y) in refs.items():old.MG[p]=x;old.MA[p]=y
  else:old.MG.update(orig_g);old.MA.update(orig_a)
  vals={p:[] for p in P};parts={p:{'DEF':[],'SECOND':[],'APR':[]} for p in P}
  for p,n,g,a,c,s,sn,r,q,group in all_rows:
   qm=vote(q/n);d=defence([c/n]*n,qm,2.8)
   second=keeper_reflex(s/sn,int(sn),qm,keeper_ref) if p=='GOL' and sn else (70 if p=='GOL' else calc_let([g/n]*n,[a/n]*n,p,qm))
   ap=apr([r/n]*n,qm)
   o=sum(v*w for v,w in zip((d,second,ap,70,70),W[p]));vals[p].append(o)
   parts[p]['DEF'].append(d);parts[p]['SECOND'].append(second);parts[p]['APR'].append(ap)
  m={p:round(float(np.mean(vals[p])),3) for p in P};component={p:{k:round(float(np.mean(v)),3) for k,v in parts[p].items()} for p in P}
  return {'means':m,'spread':round(max(m.values())-min(m.values()),3),'components':component}
 baseline=evaluate_rows(False);calibrated=evaluate_rows(True);both=evaluate_rows(True,stats["GOL"]["save_rate"])
 if fixed_refs:
  refs.update({p:(v["goals"],v["assists"]) for p,v in fixed_refs.items()})
  heldout=evaluate_rows(True,fixed_keeper)
 else:heldout=None
 old.MG.update(orig_g);old.MA.update(orig_a)
 result={'groups':groups,'players':players,'matches':games,'appearances':participants,'eligible':len(all_rows),'actual_opportunities':stats,'original_references':{'goals':orig_g,'assists':orig_a},'candidate_references':{p:{'goals':round(x,4),'assists':round(y,4)} for p,(x,y) in refs.items()},'baseline':baseline,'opportunity_reference_only':calibrated,'opportunity_plus_keeper_reference':both,'independent_fixed_reference_result':heldout,'important':'No change to LET/DEF/REF/APR/OVR equations. Candidate refs derived from same simulated data, not independently validated; goalie underrepresentation and REF need separate treatment.'}
 if save:(OUT/'v75_calibration_results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
 print(json.dumps({k:v for k,v in result.items() if k not in ('baseline','opportunity_reference_only')},ensure_ascii=False))
 print('BEFORE',baseline['means'],baseline['spread']);print('AFTER',calibrated['means'],calibrated['spread']);print('BOTH',both['means'],both['spread']);print('SECOND',baseline['components']['GOL'],both['components']['GOL'])
 return result
if __name__=='__main__':
 train=simulate(groups=500)
 test=simulate(seed=92,groups=500,fixed_refs=train['candidate_references'],fixed_keeper=train['actual_opportunities']['GOL']['save_rate'],save=False)
 train['holdout']={'seed':92,'groups':500,'original':test['baseline'],'fixed_reference':test['independent_fixed_reference_result']}
 (OUT/'v75_calibration_results.json').write_text(json.dumps(train,ensure_ascii=False,indent=2))
 print('HOLDOUT',train['holdout']['original']['spread'],train['holdout']['fixed_reference']['spread'],train['holdout']['fixed_reference']['means'])
