"""Minuto91 V7.2 independent math prototype; NOT production engine."""
import math,random,statistics,json,csv
from pathlib import Path
OUT=Path('/mnt/data/min91audit'); OUT.mkdir(exist_ok=True)
P=['GOL','ZAG','LAT','VOL','MEI','ATA','PON']
W={'GOL':(.40,.35,.10,.10,.05),'ZAG':(.45,.30,.10,.10,.05),'LAT':(.40,.35,.10,.10,.05),'VOL':(.35,.40,.10,.10,.05),'MEI':(.25,.50,.10,.10,.05),'ATA':(.20,.55,.10,.10,.05),'PON':(.20,.55,.10,.10,.05)}
MG={'ZAG':.1,'LAT':.15,'VOL':.2,'MEI':.4,'ATA':.7,'PON':.7};MA={'ZAG':.1,'LAT':.2,'VOL':.25,'MEI':.4,'ATA':.3,'PON':.3}
def clip(x,lo=40,hi=99):return min(hi,max(lo,x))
def vote(q):return clip(68+12*(q-7) if q<=8 else 80+11*(q-8))
def let(gs,ass,p,q):
 n=len(gs);g=sum(gs);a=sum(ass)
 def score(r,mu):
  z=5*(r/mu-1)
  return clip(75+(24 if z>=0 else 25)*math.tanh(z))
 sg,sa=score(g/n,MG[p]),score(a/n,MA[p]);stat=min(99,max(sg,sa)+.1*max(0,min(sg,sa)-75))
 base=70+n/(n+3)*(stat-70)
 return clip(.75*base+.25*q)
def defence(conceded,q,mu):
 n=len(conceded);r=(sum(conceded)+6*mu)/(n+6);z=math.log(mu/r)
 stat=75+(24*math.tanh(1.2*z) if z>=0 else 25*math.tanh(1.2*z))
 return clip(.75*(70+n/(n+3)*(stat-70))+.25*q)
def reflex(saves,q):
 valid=[x for x in saves if x is not None]
 if not valid:return 70.0
 n=len(valid);d=sum(valid)/n
 # common normalized scoring, with 3 saves/game -> 70; high saves rewarded without giving free position bonus
 z=(d-3)/2
 stat=clip(75+(24*math.tanh(1.4*z) if z>=0 else 25*math.tanh(1.4*z)))
 return clip(.75*(70+n/(n+3)*(stat-70))+.25*q)
def apr(results,q):
 n=len(results);p=(sum(results)+2)/(n+4)
 return clip(.9*(70+35*(2*p-1)*n/(n+4))+.1*q)
def res(present,confirmed,q):
 # confirmed None = missing vote; exclude from denominator, never assume no
 freq=(sum(present)+2)/(len(present)+4)
 valid=[x for x in confirmed if x is not None];after=(sum(valid)+2)/(len(valid)+4) if valid else .5
 base=.6*(40+59*freq)+.4*(40+59*after)
 return clip(.95*base+.05*q)
def dis(cards):
 v=70.
 for yellow,red in cards:
  if yellow or red:v=max(50,v-8*yellow-20*red)
  else:v=min(99,v+.06*(99-v))
 return v
class State:
 def __init__(self):self.prev=None;self.bad=0
 def apply(self,raw):
  if raw is None:return self.prev
  if self.prev is None:self.prev=raw;return raw
  if raw>=self.prev:self.prev=raw;self.bad=0;return raw
  self.bad=min(10,self.bad+1)
  alpha=.30+.55*(1-math.exp(-self.bad/7))
  self.prev=clip(self.prev+alpha*(raw-self.prev))
  return self.prev

def simulate(seed=91,groups=1000,season_len=40):
 rng=random.Random(seed); sums={p:[] for p in P}; jumps=[]; counts=0; gold=0; scenario=[]; audits={'res_vote_missing':0,'keeper_saves_missing':0,'carded':0}
 for group in range(groups):
  size=rng.randint(25,40);counts+=size
  players=[]
  for i in range(size):
   p=P[i%7];skill=rng.gauss(0,.9);players.append((p,skill))
  for p,skill in players:
   goals=[];ass=[];conc=[];saves=[];results=[];votes=[];presence=[];confirmed=[];cards=[]
   state={x:State() for x in ('DEF','SECOND','APR')};prevovr=None
   # per-pelada shared environment: mean goals and defense opportunities
   env=clip(rng.gauss(3,.65),1.4,5.2)
   for t in range(1,season_len+1):
    # performance draws; goals and assists Poisson via inverse transform
    def poisson(lam):
     k=0;v=1.;threshold=math.exp(-min(12,lam))
     while v>threshold:v*=rng.random();k+=1
     return k-1
    q=clip(rng.gauss(7+.7*skill,.65),0,10);votes.append(q)
    if p!='GOL':
     goals.append(poisson(MG[p]*math.exp(.55*skill)));ass.append(poisson(MA[p]*math.exp(.55*skill)))
    conc.append(poisson(max(.2,env*math.exp(-.17*skill))))
    if p=='GOL':
     if rng.random()<.07:saves.append(None);audits['keeper_saves_missing']+=1
     else:saves.append(poisson(3*math.exp(.35*skill)))
    results.append(rng.choices([0,1/3,1],[.35,.20,.45])[0])
    attendance=rng.random()<clip(.82+.06*skill,.4,.98);presence.append(attendance)
    if attendance:
     if rng.random()<.10:confirmed.append(None);audits['res_vote_missing']+=1
     else:confirmed.append(rng.random()<clip(.65+.06*skill,.25,.95))
    yy=int(rng.random()<.10);rr=int(rng.random()<.018);cards.append((yy,rr));audits['carded']+=bool(yy or rr)
    qmean=vote(statistics.mean(votes))
    # DEF environment-relative and player-relative: reference is group environment, not own team goals
    rawdef=defence(conc,qmean,env)
    rawsec=reflex(saves,qmean) if p=='GOL' else let(goals,ass,p,qmean)
    rawapr=apr(results,qmean)
    adef=state['DEF'].apply(rawdef);asec=state['SECOND'].apply(rawsec);aapr=state['APR'].apply(rawapr)
    r=res(presence,confirmed,qmean);d=dis(cards)
    w=W[p];ovr=sum(x*y for x,y in zip(w,(adef,asec,aapr,r,d)))
    if t>5 and prevovr is not None:jumps.append(ovr-prevovr)
    prevovr=ovr
   sums[p].append(ovr);gold+=ovr>=80
 return {'groups':groups,'players':counts,'participations':counts*season_len,'means':{p:round(statistics.mean(sums[p]),3) for p in P},'spread':round(max(statistics.mean(sums[p]) for p in P)-min(statistics.mean(sums[p]) for p in P),3),'gold_percent':round(100*gold/counts,2),'max_fall':round(min(jumps),3),'max_rise':round(max(jumps),3),'percentiles':{str(k):round(sorted(sum(sums.values(),[]))[int((counts-1)*k/100)],2) for k in (5,50,95)},'audits':audits}
def cases():
 data=[]
 for p,good,bad in [('ATA',1,0),('ZAG',1,6),('GOL',5,0)]:
  gs=[];ass=[];conc=[];saves=[];st=State()
  for t in range(1,31):
   x=good if t<=10 else bad
   if p=='ATA':gs.append(x);ass.append(0);raw=let(gs,ass,p,vote(9))
   elif p=='ZAG':conc.append(x);raw=defence(conc,vote(9),3)
   else:saves.append(x);raw=reflex(saves,vote(9))
   pub=st.apply(raw)
   if t in (5,10,11,13,15,20,21,30):data.append({'position':p,'match':t,'raw':round(raw,3),'published':round(pub,3)})
 return data
if __name__=='__main__':
 result=simulate(groups=100);result['cases']=cases();result['checks']={
  '10_goals_10_matches_vote9_above90':let([1]*10,[0]*10,'ATA',vote(9))>90,
  '10_goals_10_matches_vote9_value':round(let([1]*10,[0]*10,'ATA',vote(9)),3),
  'missing_saves_do_not_count_as_zero':reflex([5,None,5],vote(8))==reflex([5,5],vote(8)),
  'card_penalty_immediate':dis([(1,0)])<dis([(0,0)]),
  'no_frozen_protection':cases()[7]['published']>cases()[7]['raw']
 }
 (OUT/'v72_results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
 with (OUT/'v72_scenarios.csv').open('w',newline='') as f:
  writer=csv.DictWriter(f,fieldnames=['position','match','raw','published']);writer.writeheader();writer.writerows(result['cases'])
 print(json.dumps({k:v for k,v in result.items() if k!='cases'},ensure_ascii=False))
