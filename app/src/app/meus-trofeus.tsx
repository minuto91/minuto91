// REV-126 (V10.0): página exclusiva "Meus Troféus" — acervo completo (Sala de Troféus) e histórico por temporada/ano
// (Meus Prêmios). Mesmos dados e contadores de antes; só mudou o lugar.
import { useEffect, useState } from 'react';

import { friendly } from '../lib/errors';
import { CareerSummary, loadCareerSummary } from '../lib/careerv2';
import { MyAwardsList } from '../lib/myawards';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { Text } from '../lib/text';
import { colors } from '../lib/theme';
import { TrophyRoom } from '../lib/trophies';
import { ErrorText, LoadingBlock, Screen, Sub } from '../lib/ui';
import { scopedTitles, SeasonTitle, showMyAwards, showOrigin } from '../lib/v87logic';

export default function MeusTrofeus() {
  const { session } = useAuth();
  const uid = session?.user.id ?? '';
  const [career, setCareer] = useState<CareerSummary | null>(null);
  const [titles, setTitles] = useState<SeasonTitle[] | null>(null);
  const [name, setName] = useState<string | undefined>();
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!uid) return;
    let alive = true;
    (async () => {
      try {
        const [c, t, { data: p }] = await Promise.all([
          loadCareerSummary(uid),
          supabase.rpc('get_player_season_titles', { p_user: uid }),
          supabase.rpc('get_my_profile'),
        ]);
        if (!alive) return;
        setCareer(c);
        setTitles(t.error || !(t.data as { visible?: boolean } | null)?.visible ? null : ((t.data as { items: SeasonTitle[] }).items ?? []));
        setName((p as { display_name?: string } | null)?.display_name);
      } catch (e) {
        if (alive) setErr(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [uid]);

  if (!career) {
    return (
      <Screen>
        <ErrorText>{err}</ErrorText>
        {!err && <LoadingBlock />}
      </Screen>
    );
  }
  if (!career.visible) return <Screen><Sub>Carreira indisponível.</Sub></Screen>;
  const items = scopedTitles(titles, null);
  return (
    <Screen>
      <TrophyRoom userId={uid} counts={career.trophies} partial={career.partial} shareName={name} />
      {showMyAwards(items) && (
        <>
          <Text style={{ fontSize: 19, lineHeight: 25, fontWeight: '700', color: colors.ink, marginTop: 8 }}>Por temporada</Text>
          <MyAwardsList items={items} withOrigin={showOrigin(titles ?? [])} />
        </>
      )}
    </Screen>
  );
}
