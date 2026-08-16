// Placeholder Database type. Once the schema in supabase/migrations/ is
// applied to a real Supabase project, replace this file with the generated
// types:
//
//   npx supabase gen types typescript --project-id <ref> > src/types/supabase.ts
//
// or, for local dev against `supabase start`:
//
//   npm run db:types
//
// Left loose (rather than hand-typing all 30 tables) so it compiles now and
// gets replaced with an accurate, generated source of truth before real
// data-access code leans on column-level type safety.
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  public: {
    Tables: {
      [key: string]: {
        Row: Record<string, Json>;
        Insert: Record<string, Json>;
        Update: Record<string, Json>;
      };
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
};
