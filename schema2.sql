-- รันหลัง schema.sql (รันซ้ำได้) : ชำระเงิน สลิป Gallery และ Storage
alter table settings add column if not exists qr_path text, add column if not exists pay_mode text default 'prepay';
alter table bookings add column if not exists slip_path text;
create table if not exists gallery(id bigserial primary key,path text not null,sort int default 0,created_at timestamptz default now());
alter table gallery enable row level security;
drop policy if exists g1 on gallery; create policy g1 on gallery for select to anon,authenticated using(true);
drop policy if exists g2 on gallery; create policy g2 on gallery for insert to authenticated with check(true);
drop policy if exists g3 on gallery; create policy g3 on gallery for delete to authenticated using(true);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('assets','assets',true,5242880,array['image/jpeg','image/png','image/webp']),
 ('slips','slips',false,5242880,array['image/jpeg','image/png','application/pdf'])
on conflict(id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists s1 on storage.objects; create policy s1 on storage.objects for insert to authenticated with check(bucket_id='assets');
drop policy if exists s2 on storage.objects; create policy s2 on storage.objects for delete to authenticated using(bucket_id='assets');
drop policy if exists s3 on storage.objects; create policy s3 on storage.objects for insert to anon,authenticated with check(bucket_id='slips');
drop policy if exists s4 on storage.objects; create policy s4 on storage.objects for select to authenticated using(bucket_id='slips');

create or replace function refund_flag() returns trigger language plpgsql as $$
begin if new.status='CANCELLED' and old.status<>'CANCELLED' and old.pay='PAID' then new.pay:='REFUND PENDING'; end if; return new; end $$;
drop trigger if exists t_refund on bookings;
create trigger t_refund before update on bookings for each row execute function refund_flag();

create or replace function public_status() returns json language sql security definer set search_path=public as $$
 select json_build_object('open',open,'paused',paused,'locations',locations,'day',day,'qr',qr_path,'pay_mode',pay_mode) from settings where id=1 $$;

create or replace function attach_slip(p_code text,p_pin text,p_path text) returns json language plpgsql security definer set search_path=public as $$
begin
 update bookings set slip_path=p_path,pay='PENDING VERIFICATION',updated_at=now()
 where code=upper(trim(p_code)) and pin=trim(p_pin) and status<>'CANCELLED' and pay in('UNPAID','PENDING VERIFICATION');
 if not found then return json_build_object('ok',false); end if;
 perform lg(upper(trim(p_code)),'SLIP',null,null,null); return json_build_object('ok',true);
end $$;

create or replace function admin_set_pay(p_code text,p_pay text,p_reason text) returns json language plpgsql security definer set search_path=public as $$
begin
 perform chk();
 if p_pay not in('UNPAID','PENDING VERIFICATION','PAID','REFUND PENDING','REFUNDED') then return json_build_object('ok',false); end if;
 update bookings set pay=p_pay,updated_at=now() where code=p_code;
 perform lg(p_code,'PAY:'||p_pay,null,null,p_reason); return json_build_object('ok',true);
end $$;

create or replace function admin_save_pay(p_mode text,p_qr text) returns void language plpgsql security definer set search_path=public as $$
begin perform chk(); update settings set pay_mode=p_mode,qr_path=p_qr where id=1; end $$;
