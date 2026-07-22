-- ============================================================
-- COUPE DU PRÉFET 2026 — TGV, 1ère édition
-- Schéma Supabase/PostgreSQL : inscription joueurs + licence
-- ============================================================

-- 1. EXTENSION nécessaire pour gen_random_uuid()
create extension if not exists pgcrypto;

-- 2. TABLE CLUBS
create table if not exists clubs (
  id uuid primary key default gen_random_uuid(),
  nom text not null unique,
  created_at timestamptz default now()
);

-- 3. TABLE JOUEURS
create table if not exists joueurs (
  id uuid primary key default gen_random_uuid(),
  n_licence text unique,                     -- généré automatiquement (trigger)
  nom_prenom text not null,
  date_naissance date not null,
  lieu_naissance text not null,
  club_id uuid references clubs(id),
  photo_url text,                            -- chemin dans le bucket Storage
  saison text not null default '2026',
  statut text not null default 'en_attente'  -- en_attente | valide | rejete
    check (statut in ('en_attente','valide','rejete')),
  created_at timestamptz default now()
);

create index if not exists idx_joueurs_club on joueurs(club_id);
create index if not exists idx_joueurs_licence on joueurs(n_licence);

-- ============================================================
-- 4. GÉNÉRATION AUTOMATIQUE DU N° DE LICENCE : TGV-2026-0001
-- ============================================================

-- Séquence par saison (une séquence par année si besoin plus tard)
create sequence if not exists licence_seq_2026 start 1;

create or replace function generer_n_licence()
returns trigger as $$
declare
  seq_name text;
  next_val integer;
begin
  seq_name := 'licence_seq_' || new.saison;

  -- crée la séquence de la saison si elle n'existe pas encore
  if not exists (select 1 from pg_sequences where sequencename = seq_name) then
    execute format('create sequence %I start 1', seq_name);
  end if;

  execute format('select nextval(%L)', seq_name) into next_val;

  new.n_licence := 'TGV-' || new.saison || '-' || lpad(next_val::text, 4, '0');
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_generer_n_licence on joueurs;
create trigger trg_generer_n_licence
  before insert on joueurs
  for each row
  when (new.n_licence is null)
  execute function generer_n_licence();

-- ============================================================
-- 5. VUE PUBLIQUE DE VÉRIFICATION (accessible via QR code)
--    Expose uniquement les champs nécessaires, jamais toute la table
-- ============================================================

create or replace view verification_publique as
select
  j.n_licence,
  j.nom_prenom,
  j.date_naissance,
  j.lieu_naissance,
  c.nom as club,
  j.photo_url,
  j.saison,
  j.statut
from joueurs j
left join clubs c on c.id = j.club_id;

-- ============================================================
-- 6. RLS (Row Level Security)
-- ============================================================

alter table joueurs enable row level security;
alter table clubs enable row level security;

-- Inscription publique : n'importe qui peut créer une fiche joueur
drop policy if exists "insertion_publique_joueurs" on joueurs;
create policy "insertion_publique_joueurs"
  on joueurs for insert
  to anon
  with check (true);

-- Lecture des clubs (pour peupler le select du formulaire)
drop policy if exists "lecture_publique_clubs" on clubs;
create policy "lecture_publique_clubs"
  on clubs for select
  to anon
  using (true);

-- Le formulaire peut aussi créer un club à la volée si non listé
drop policy if exists "insertion_publique_clubs" on clubs;
create policy "insertion_publique_clubs"
  on clubs for insert
  to anon
  with check (true);

-- IMPORTANT : pas de policy select directe sur joueurs pour anon
-- -> la vérification publique passe uniquement par la vue ci-dessous
grant select on verification_publique to anon;

-- Pour l'administration (comité TGV), utiliser la clé service_role
-- côté back-office : accès total, RLS ignorée automatiquement.

-- ============================================================
-- 7. STORAGE : bucket pour les photos 4x4
-- ============================================================
-- À exécuter une fois (ou via l'interface Supabase Storage) :
-- insert into storage.buckets (id, name, public)
--   values ('photos-joueurs', 'photos-joueurs', true)
--   on conflict (id) do nothing;

-- Policies du bucket (à créer dans Storage > Policies) :
-- - INSERT pour anon : autorisé (upload depuis le formulaire)
-- - SELECT pour public : autorisé (photo visible sur la licence/vérif)
-- - UPDATE / DELETE : réservé à service_role uniquement
