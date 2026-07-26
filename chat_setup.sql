-- ============================================================
-- إعداد ميزة المراسلة بين الحسابات — نفّذ الملف ده مرة واحدة بس
-- من: Supabase Dashboard → مشروعك → SQL Editor → New query → Run
-- ============================================================

create extension if not exists pgcrypto;

-- بروفايل مبسّط لكل مستخدم (اسم + رقم حساب) عشان تقدر تدور على
-- حساب حد تاني بالرقم بتاعه وتبدأ تكلمه.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text,
  phone_norm text,
  name text,
  updated_at timestamptz not null default now()
);
create index if not exists profiles_phone_norm_idx on public.profiles(phone_norm);

-- محادثة بين شخصين (صف واحد لكل زوج مستخدمين)
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  last_message text,
  last_message_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint conversations_users_check check (user_a <> user_b),
  constraint conversations_unique_pair unique (user_a, user_b)
);

-- الرسائل نفسها (نص / ملف / جهة اتصال)
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  msg_type text not null default 'text' check (msg_type in ('text','file','contact')),
  body text,
  file_path text,
  file_name text,
  file_size bigint,
  file_mime text,
  contact_payload jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists messages_conversation_idx on public.messages(conversation_id, created_at);
create index if not exists messages_recipient_idx on public.messages(recipient_id, created_at);

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;

-- profiles: أي مستخدم مسجّل دخول يقدر يدوّر على أي بروفايل (بس بالرقم)،
-- لكن محدّش يقدر يعدّل غير بروفايله هو بس.
drop policy if exists "profiles_select_authenticated" on public.profiles;
create policy "profiles_select_authenticated" on public.profiles
  for select using (auth.role() = 'authenticated');

drop policy if exists "profiles_upsert_own" on public.profiles;
create policy "profiles_upsert_own" on public.profiles
  for insert with check (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

-- conversations: كل واحد يشوف / يعدّل بس المحادثات اللي هو طرف فيها
drop policy if exists "conversations_select_own" on public.conversations;
create policy "conversations_select_own" on public.conversations
  for select using (auth.uid() = user_a or auth.uid() = user_b);

drop policy if exists "conversations_insert_own" on public.conversations;
create policy "conversations_insert_own" on public.conversations
  for insert with check (auth.uid() = user_a or auth.uid() = user_b);

drop policy if exists "conversations_update_own" on public.conversations;
create policy "conversations_update_own" on public.conversations
  for update using (auth.uid() = user_a or auth.uid() = user_b);

-- messages: كل واحد يشوف بس الرسائل اللي هو مرسلها أو مستقبلها، ومينفعش
-- حد يبعت رسالة منتحل شخصية حد تاني أو يبعت لمحادثة هو مش طرف فيها
drop policy if exists "messages_select_own" on public.messages;
create policy "messages_select_own" on public.messages
  for select using (auth.uid() = sender_id or auth.uid() = recipient_id);

drop policy if exists "messages_insert_own" on public.messages;
create policy "messages_insert_own" on public.messages
  for insert with check (
    auth.uid() = sender_id
    and exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and ((c.user_a = sender_id and c.user_b = recipient_id)
          or (c.user_b = sender_id and c.user_a = recipient_id))
    )
  );

drop policy if exists "messages_update_own_read" on public.messages;
create policy "messages_update_own_read" on public.messages
  for update using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- تفعيل الإرسال اللحظي (Realtime) على جدولي المحادثات والرسائل
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.conversations;
  exception when duplicate_object then null;
  end;
end $$;

-- باكت تخزين خاص (مش عام) للملفات المُرسَلة جوّه المحادثات
insert into storage.buckets (id, name, public)
values ('chat-files', 'chat-files', false)
on conflict (id) do nothing;

drop policy if exists "chat_files_insert" on storage.objects;
create policy "chat_files_insert" on storage.objects
  for insert with check (bucket_id = 'chat-files' and auth.role() = 'authenticated');

-- تحميل الملف مسموح بس لطرفي المحادثة اللي الرسالة بتاعته اتبعتت فيها
drop policy if exists "chat_files_select" on storage.objects;
create policy "chat_files_select" on storage.objects
  for select using (
    bucket_id = 'chat-files' and
    exists (
      select 1 from public.messages m
      where m.file_path = name
        and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())
    )
  );

-- ============================================================
-- خلصنا. بعد التشغيل، تأكد من لوحة Supabase إن:
--  Database → Replication → supabase_realtime فعّالة على جدولي
--  messages و conversations (لو الأمر فوق ماعملهاش تلقائي لأي سبب).
-- ============================================================
