import { Session } from '@supabase/supabase-js';
import {
  createContext,
  ReactNode,
  useCallback,
  useContext,
  useEffect,
  useState,
} from 'react';

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

async function fetchOnboarded(s: Session | null): Promise<boolean | null> {
  if (!s) return null;
  const { data } = await supabase
    .from('profiles')
    .select('adult_declared_at, terms_accepted_at')
    .eq('id', s.user.id)
    .maybeSingle();
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
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
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
