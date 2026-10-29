import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';

import { loadSeasons, Season } from '../../../lib/career';
import { todayIn } from '../../../lib/dates';
import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { AwardsView, AwardsState } from '../../../lib/seasonawards';
import { supabase } from '../../../lib/supabase';

// V8.7: Artilheiro da Temporada, Maestro da Temporada e Luva de Ouro, com a exceção administrativa da Luva (F01).
// Todas as regras e a publicação são do servidor (get_season_awards, grant/revoke_golden_glove_exception).
export default function PremiosTemporada() {
  const { id, season: seasonParam } = useLocalSearchParams<{ id: string; season?: string }>();
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(seasonParam ?? null);
  const [loaded, setLoaded] = useState<{ seasonId: string; data: AwardsState } | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let alive = true;
    loadSeasons(id)
      .then((ss) => {
        if (!alive) return;
        const today = todayIn();
        const started = ss.filter((s) => s.starts_on <= today);
        setSeasons(started);
        setSeasonId((cur) => cur ?? started.find((s) => s.ends_on < today)?.id ?? started[0]?.id ?? null);
      })
      .catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id]);

  useEffect(() => {
    if (!seasonId) return;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_season_awards', { p_season: seasonId });
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      setMsg(null);
      setLoaded({ seasonId, data: data as AwardsState });
    })();
    return () => {
      alive = false;
    };
  }, [seasonId, reload]);

  const state = loaded && loaded.seasonId === seasonId ? loaded.data : null;

  async function run(fn: 'grant_golden_glove_exception' | 'revoke_golden_glove_exception', args: Record<string, unknown>) {
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    notify(fn === 'grant_golden_glove_exception' ? 'Exceção registrada' : 'Exceção revogada');
    setReload((n) => n + 1);
  }

  return (
    <AwardsView
      state={state}
      seasons={seasons}
      seasonId={seasonId}
      onSeason={(s) => {
        setMsg(null);
        setSeasonId(s);
      }}
      busy={busy}
      msg={msg}
      onGrant={(percent, minMatches, reason) =>
        confirm(
          'Autorizar exceção?',
          `O requisito da Luva de Ouro passa a ser ${percent}% das partidas e no mínimo ${minMatches} como goleiro. Fica registrado com o seu motivo.`,
          'Autorizar',
          () => run('grant_golden_glove_exception', { p_season: seasonId, p_min_percent: percent, p_min_matches: minMatches, p_reason: reason }),
        )
      }
      onRevoke={(reason) =>
        confirm('Revogar exceção?', 'A Luva concedida por exceção será desfeita.', 'Revogar', () =>
          run('revoke_golden_glove_exception', { p_season: seasonId, p_reason: reason }),
        )
      }
    />
  );
}
