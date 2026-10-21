// Traduz os erros das RPCs do banco para mensagens humanas.
const MAP: Record<string, string> = {
  ONBOARDING_REQUIRED: 'Conclua seu cadastro primeiro.',
  ADULT_DECLARATION_REQUIRED: 'É preciso declarar que você tem 18 anos ou mais.',
  TERMS_ACCEPTANCE_REQUIRED: 'É preciso aceitar os Termos de Uso.',
  INVALID_NAME: 'Nome inválido (2 a 100 caracteres).',
  INVALID_POSITION: 'Escolha uma posição.',
  POSITION_REQUIRED: 'Escolha sua posição.',
  INVALID_INVITE: 'Convite inválido.',
  INVALID_OR_EXPIRED_INVITE: 'Convite inválido, expirado ou já usado.',
  PELADA_FULL: 'Essa pelada já tem 100 membros.',
  PELADA_NOT_ACTIVE: 'Essa pelada não está ativa.',
  MEMBERSHIP_NOT_REJOINABLE: 'Você não pode voltar a essa pelada.',
  ADMIN_REQUIRED: 'Só o administrador pode fazer isso.',
  ASSISTANT_LIMIT_REACHED: 'Limite de assistentes atingido.',
  INVALID_SUCCESSOR: 'Esse jogador não pode ser sucessor.',
  INVALID_MEMBER: 'Jogador inválido.',
  ASSISTANT_REQUIRES_ACCOUNT: 'O assistente precisa ter conta no app.',
};

export function friendly(message?: string | null): string {
  if (!message) return 'Algo deu errado. Tente de novo.';
  for (const key of Object.keys(MAP)) if (message.includes(key)) return MAP[key];
  return message;
}
