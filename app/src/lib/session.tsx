import { Session } from '@supabase/supabase-js';
import {
  createContext,
  ReactNode,
  useCallback,
  useContext,
  useEffect,
  useState,
} from 'react';

import { refreshPushRegistration, unregisterPush } from './push';
import { resetPurchasesUser } from './purchases';
import { supabase } from './supabase';

type AuthState = {
  session: Session | null;
  loading: boolean;
  /** null = ainda carregando; false = falta onboarding (18+ e termos) */
  onboarded: boolean | null;
  refresh: () => Promise<void>;
};

const AuthContext = createContext<AuthState>({
  session: null,
  loading: true,
  onboarded: null,
  refresh: async () => {},
});

export const useAuth = () => useContext(AuthContext);

/** Sair da conta: antes, este aparelho deixa de receber os avisos dela (035). Sem rede, sai assim mesmo. */
export async function signOut() {
  await unregisterPush().catch(() => {});
  await supabase.auth.signOut();
}

// Cadastro completo = 18+ e termos declarados no perfil E aceite da versão vigente de Termos e Privacidade
// (A18, migração 037). Banco sem a 037: vale só o perfil.
async function fetchOnboarded(s: Session | null): Promise<boolean | null> {
  if (!s) return null;
  const profileOk = await fetchProfileOnboarded(s);
  if (!profileOk) return false;
  const { data, error } = await supabase.rpc('get_legal_status');
  if (error) return true;
  return !!(data as { accepted: boolean } | null)?.accepted;
}

async function fetchProfileOnboarded(s: Session): Promise<boolean> {
  // Desde a 029 só id, nome e foto são lidos direto de profiles; o resto vem por RPC.
  const { data, error } = await supabase.rpc('get_my_profile');
  if (error) {
    // Banco ainda sem a 029: leitura antiga.
    const { data: old } = await supabase
      .from('profiles')
      .select('adult_declared_at, terms_accepted_at')
      .eq('id', s.user.id)
      .maybeSingle();
    return !!(old?.adult_declared_at && old?.terms_accepted_at);
  }
  return !!(data?.adult_declared_at && data?.terms_accepted_at);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [onboarded, setOnboarded] = useState<boolean | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session);
      setOnboarded(await fetchOnboarded(data.session));
      setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      setSession(s);
      if (!s) resetPurchasesUser(); // a próxima conta não herda o comprador da loja
      // Com permissão já dada, mantém o aparelho registrado para esta conta (não pergunta nada).
      else if (event === 'SIGNED_IN' || event === 'INITIAL_SESSION') setTimeout(() => refreshPushRegistration().catch(() => {}), 0);
      // Não chamar o Supabase dentro do callback: adia para o próximo ciclo.
      setTimeout(async () => setOnboarded(await fetchOnboarded(s)), 0);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  const refresh = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    setOnboarded(await fetchOnboarded(data.session));
  }, []);

  return (
    <AuthContext.Provider value={{ session, loading, onboarded, refresh }}>
      {children}
    </AuthContext.Provider>
  );
}
