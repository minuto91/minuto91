import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';

import { loadReadableSeasons, Season } from '../../../lib/career';
import { friendly } from '../../../lib/errors';
import { supabase } from '../../../lib/supabase';
import { CraqueView, State } from '../../../lib/craqueview';

export default function CraqueTemporada() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [state, setState] = useState<State | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    loadReadableSeasons(id)
      .then((ss) => {
        setSeasons(ss);
        setSeasonId((cur) => cur ?? ss.find((s) => s.status === 'closed')?.id ?? ss[0]?.id ?? null);
      })
      .catch((e) => setMsg(friendly((e as Error).message)));
  }, [id]);

  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    (async () => {
      if (!seasonId) return;
      const { data, error } = await supabase.rpc('get_season_craque', { p_season: seasonId });
      if (!alive) return;
      if (error) setMsg(friendly(error.message));
      else {
        setMsg(null);
        setState(data as State);
      }
    })();
    const t = setInterval(() => setNow(Date.now()), 30000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [seasonId, tick]);
  const load = async () => setTick((n) => n + 1);

  const run = async (fn: 'open_season_craque_poll' | 'confirm_season_craque' | 'cast_season_craque_vote', candidate?: string) => {
    if (!seasonId) return;
    setBusy(true);
    const { error } = await supabase.rpc(fn, candidate ? { p_season: seasonId, p_candidate: candidate } : { p_season: seasonId });
    setBusy(false);
    if (error) setMsg(friendly(error.message));
    await load();
  };

  return (
    <CraqueView
      state={state}
      seasons={seasons}
      seasonId={seasonId}
      onSeason={(v) => {
        setState(null);
        setSeasonId(v);
      }}
      busy={busy}
      msg={msg}
      now={now}
      onOpen={() => run('open_season_craque_poll')}
      onConfirm={() => run('confirm_season_craque')}
      onVote={(c) => run('cast_season_craque_vote', c)}
    />
  );
}
