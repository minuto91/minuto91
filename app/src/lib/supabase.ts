import 'react-native-url-polyfill/auto';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';

import { chunkedStorage } from './securestorage';

// V6.1: nos apps nativos a sessão fica no armazenamento seguro (em partes, migrando a do AsyncStorage);
// na web continua no AsyncStorage (localStorage), que é o que existe lá.
const storage =
  Platform.OS === 'web'
    ? AsyncStorage
    : chunkedStorage(
        {
          getItem: (k) => SecureStore.getItemAsync(k),
          setItem: (k, v) => SecureStore.setItemAsync(k, v),
          removeItem: (k) => SecureStore.deleteItemAsync(k),
        },
        AsyncStorage,
      );

export const supabase = createClient(
  process.env.EXPO_PUBLIC_SUPABASE_URL!,
  process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY!,
  {
    auth: {
      storage,
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: false,
    },
  },
);
