"""Minuto91 V7.7 experimental fixes, not production SQL. Keeps V7.5 scoring curves and positional weights."""
import math, statistics, json
from collections import deque
from pathlib import Path
from v72_corrected import P,W,clip,vote,let as calc_let,defence,reflex,apr
from v73_engine import MovingState, mk
OUT=Path(__file__).parent

def resenha(votes,player_id,attended=True):
    if not attended or votes is None:return None
    valid={str(k):bool(v) for k,v in votes.items() if str(k)!=str(player_id) and v is not None}
    if len(valid)<2:return None
    yes=sum(valid.values())
    return yes>=2 and yes>len(valid)/2

def step_dis(current,yellow=0,red=0):
    if yellow or red:return max(50.,current-8*yellow-20*red)
    return min(99.,current+.06*(99.-current))

def prior_payload(rows):
    last=rows[-1]
    return {'attrs':{k:last[k] for k in ('DEF','SECOND','APR','RES','DIS')},
            'evidence':last['evidence'], 'q':last['vote_mean'], 'position':last['position']}

def evaluate(events,pos,env=3,previous=None):
    # The 50% carryover applies to each attribute's prior-season *valid observation count*, capped to 20.
    # 20 valid prior matches -> 10 effective observations (50% of 20).
    prev=previous or {}; prior=prev.get('attrs',prev)
    evidence=prev.get('evidence',{})
    states={a:MovingState(prior.get(a)) for a in ('DEF','SECOND','APR')}
    hist={'DEF':[],'SECOND':[],'APR':[]}; votes={'DEF':[],'SECOND':[],'APR':[]}
    rounds=0; played=0; attendance=[]; after=[]; last_res=prior.get('RES',70.);last_dis=prior.get('DIS',70.)
    out=[]
    for idx,e in enumerate(events,1):
        rounds+=1; active=e.get('played',True); attendance.append(bool(active))
        if active:
            played+=1
            q=e.get('q')
            # Independent evidence and vote accumulators. No new valid measurement => no attribute update.
            for a,valid in (('DEF',e.get('conceded') is not None),
                            ('SECOND',e.get('saves') is not None if pos=='GOL' else e.get('goals') is not None and e.get('assists') is not None),
                            ('APR',e.get('result') is not None)):
                if valid:
                    hist[a].append(e)
                    if q is not None:votes[a].append(vote(q))
            after.append(resenha(e.get('resenha_votes'),e.get('id','self')))
            last_dis=step_dis(last_dis,e.get('yellow',0),e.get('red',0))
        attrs={}
        for a in ('DEF','SECOND','APR'):
            n=len(hist[a]); st=states[a]
            if not active or not n or (a=='DEF' and e.get('conceded') is None) or (a=='SECOND' and (e.get('saves') is None if pos=='GOL' else (e.get('goals') is None or e.get('assists') is None))) or (a=='APR' and e.get('result') is None):
                attrs[a]=st.published if st.published is not None else 70.
                continue
            q=statistics.mean(votes[a]) if votes[a] else prior.get('q',70.)
            if a=='DEF':raw=defence([v['conceded'] for v in hist[a]],q,env)
            elif a=='SECOND':
                raw=reflex([v['saves'] for v in hist[a]],q) if pos=='GOL' else calc_let([v['goals'] for v in hist[a]],[v['assists'] for v in hist[a]],pos,q)
            else:raw=apr([v['result'] for v in hist[a]],q)
            if previous:
                old_n=evidence.get(a,0)
                prior_strength=.5*min(20,old_n)
                if prior_strength>0:
                    raw=(prior_strength*prior.get(a,raw)+n*raw)/(prior_strength+n)
            attrs[a]=st.update(raw)
        # RES based on attendance and valid after-match outcomes; missing votes are neutral, not negative.
        freq=(sum(attendance)+2)/(len(attendance)+4)
        known=[x for x in after if x is not None]
        if known:
            post=(sum(known)+2)/(len(known)+4)
            qvalid=[vote(x.get('q')) for x in events[:idx] if x.get('played',True) and x.get('q') is not None]
            qmean=statistics.mean(qvalid) if qvalid else 70
            last_res=clip(.95*(.6*(40+59*freq)+.4*(40+59*post))+.05*qmean)
        elif not previous:
            last_res=clip(.95*(.6*(40+59*freq)+.4*(40+59*.5))+.05*70)
        # If prior RES exists and there are no confirmed after-match observations, update attendance
        # without changing the unknown post-game contribution.
        else:
            prior_freq=.5
            last_res=clip(prior['RES']+.95*.6*59*(freq-prior_freq))
        attrs['RES']=last_res;attrs['DIS']=last_dis
        ovr=clip(sum(x*y for x,y in zip((attrs['DEF'],attrs['SECOND'],attrs['APR'],attrs['RES'],attrs['DIS']),W[pos])))
        out.append({'round':idx,'played_games':played,'ovr':ovr if played>=5 else None,'internal_ovr':ovr,
                    **attrs,'evidence':{a:len(hist[a]) for a in hist},'vote_mean':statistics.mean(votes['SECOND']) if votes['SECOND'] else 70.,'position':pos})
    return out

def checks():
    t={}
    base=[mk(saves=4,q=7)]*6
    t['REF_missing_preserved']=evaluate(base+[mk(saves=None,q=10)],'GOL')[-1]['SECOND']==evaluate(base,'GOL')[-1]['SECOND']
    base=[mk(result=1,q=7)]*6
    t['APR_missing_preserved']=evaluate(base+[mk(result=None,q=10)],'ATA')[-1]['APR']==evaluate(base,'ATA')[-1]['APR']
    t['two_voters_both_yes']=resenha({'a':True,'b':True},'self') is True
    t['two_voters_split_no']=resenha({'a':True,'b':False},'self') is False
    t['one_voter_unknown']=resenha({'a':True},'self') is None
    t['self_excluded']=resenha({'self':True,'a':True,'b':False},'self') is False
    t['three_voters_majority']=resenha({'a':True,'b':True,'c':False},'self') is True
    t['five_voters_tie_no']=resenha({'a':True,'b':True,'c':False,'d':False},'self') is False
    t['initial_ovr_hidden']=all(x['ovr'] is None for x in evaluate([mk()]*4,'ATA'))
    t['fifth_ovr_visible']=evaluate([mk()]*5,'ATA')[-1]['ovr'] is not None
    t['absence_does_not_recover_dis']=evaluate([mk(yellow=1)]*5+[mk(played=False)],'ATA')[-1]['DIS']==evaluate([mk(yellow=1)]*5,'ATA')[-1]['DIS']
    old=evaluate([mk(yellow=1)]*6,'ATA');p=prior_payload(old)
    t['season_dis_continuity']=abs(evaluate([mk()],'ATA',previous=p)[-1]['DIS']-step_dis(old[-1]['DIS']))<1e-8
    p20=prior_payload(evaluate([mk(goals=1)]*20,'ATA'))
    t['season_20_games_half_strength']=.5*min(20,p20['evidence']['SECOND'])==10
    t['season_6_games_half_strength']=.5*min(20,6)==3
    t['striker_10_goals_gt90']=evaluate([mk(goals=1,q=9)]*10,'ATA')[-1]['SECOND']>90
    t['missing_ref_not_zero']=evaluate([mk(saves=5)]*5+[mk(saves=0)],'GOL')[-1]['SECOND']<evaluate([mk(saves=5)]*5,'GOL')[-1]['SECOND']
    t['retro_replay']=evaluate([mk(goals=1)]*8,'ATA')==evaluate([mk(goals=1)]*8,'ATA')
    t['retro_correction_effect']=evaluate([mk(goals=1)]*8,'ATA')[-1]['SECOND']!=evaluate([mk(goals=0)]+[mk(goals=1)]*7,'ATA')[-1]['SECOND']
    t['res_attendance_decreases_on_absence']=evaluate([mk()]*5+[mk(played=False)],'ATA')[-1]['RES']<evaluate([mk()]*5,'ATA')[-1]['RES']
    t['no_ovr_jump_from_eligibility']=abs(evaluate([mk()]*5,'ATA')[-1]['ovr']-evaluate([mk()]*5,'ATA')[-1]['internal_ovr'])<1e-9
    t['attributes_bounds']=all(40<=row[k]<=99 for row in evaluate([mk(goals=1,q=9)]*10+[mk(goals=0,q=6)]*20,'ATA') for k in ('DEF','SECOND','APR','RES','DIS','internal_ovr'))
    return t

if __name__=='__main__':
    tests=checks(); report={'passed':sum(tests.values()),'total':len(tests),'checks':tests,'striker_let':evaluate([mk(goals=1,q=9)]*10,'ATA')[-1]['SECOND'],'note':'Experimental reference implementation, not SQL production engine; V7.5 positional references remain unchanged.'}
    (OUT/'v77_validation.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
    print(json.dumps(report,ensure_ascii=False,indent=2))
