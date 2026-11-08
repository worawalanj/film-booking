-- วางทั้งไฟล์ใน Supabase > SQL Editor แล้วกด Run
create table settings(
  id int primary key default 1 check(id=1),
  total int default 70, sale_limit int default 60, personal int default 7, reserve int default 3,
  booking_open boolean default true, special_round boolean default false,
  edit_deadline timestamptz default '2026-11-30 23:59:59+07', low_alert int default 5);
insert into settings(id) values(1);

create table orders(
  id uuid primary key default gen_random_uuid(), code text unique not null,
  name text not null, phone text not null, qty int not null check(qty>0),
  status text not null default 'confirmed', created_at timestamptz default now(),
  updated_at timestamptz default now(), cancelled_at timestamptz);

create table stock_logs(
  id bigserial primary key, order_id uuid, code text, action text, qty_change int,
  created_at timestamptz default now());

alter table settings enable row level security;
alter table orders enable row level security;
alter table stock_logs enable row level security;
create policy admin_read_orders on orders for select to authenticated using(true);
create policy admin_read_logs on stock_logs for select to authenticated using(true);
-- ไม่มี policy ให้ anon = ลูกค้าเข้าตารางตรงๆ ไม่ได้ ต้องผ่านฟังก์ชันด้านล่างเท่านั้น

create function public_status() returns json language sql security definer set search_path=public as $$
  select json_build_object('open',booking_open,'special',special_round,'edit_open',now()<=edit_deadline)
  from settings where id=1 $$;

create function create_order(p_name text,p_phone text,p_qty int) returns json
language plpgsql security definer set search_path=public as $$
declare s settings; sold int; c text; oid uuid;
begin
  select * into s from settings where id=1 for update;  -- ล็อก กันกดพร้อมกัน
  if not s.booking_open then return json_build_object('ok',false,'error','CLOSED'); end if;
  if p_qty is null or p_qty<1 or p_qty>s.sale_limit or length(trim(p_name))<1 or length(trim(p_phone))<6 then
    return json_build_object('ok',false,'error','INVALID'); end if;
  select coalesce(sum(qty),0) into sold from orders where status='confirmed';
  if sold+p_qty>s.sale_limit then return json_build_object('ok',false,'error','NOT_ENOUGH'); end if;
  c := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  insert into orders(code,name,phone,qty) values(c,trim(p_name),trim(p_phone),p_qty) returning id into oid;
  insert into stock_logs(order_id,code,action,qty_change) values(oid,c,'BOOK',p_qty);
  if sold+p_qty>=s.sale_limit then update settings set booking_open=false,special_round=false where id=1; end if;
  return json_build_object('ok',true,'code',c);
end $$;

create function update_order(p_code text,p_phone text,p_qty int) returns json
language plpgsql security definer set search_path=public as $$
declare s settings; o orders; sold int; d int;
begin
  select * into s from settings where id=1 for update;
  if now()>s.edit_deadline then return json_build_object('ok',false,'error','DEADLINE'); end if;
  select * into o from orders where code=upper(trim(p_code)) and phone=trim(p_phone) and status='confirmed';
  if not found then return json_build_object('ok',false,'error','NOT_FOUND'); end if;
  if p_qty is null or p_qty<1 or p_qty>s.sale_limit then return json_build_object('ok',false,'error','INVALID'); end if;
  d := p_qty-o.qty;
  select coalesce(sum(qty),0) into sold from orders where status='confirmed';
  if d>0 then
    if not s.booking_open then return json_build_object('ok',false,'error','CLOSED'); end if;
    if sold+d>s.sale_limit then return json_build_object('ok',false,'error','NOT_ENOUGH'); end if;
  end if;
  update orders set qty=p_qty,updated_at=now() where id=o.id;
  insert into stock_logs(order_id,code,action,qty_change) values(o.id,o.code,'EDIT',d);
  if sold+d>=s.sale_limit then update settings set booking_open=false,special_round=false where id=1; end if;
  return json_build_object('ok',true,'code',o.code);
end $$;

create function admin_stats() returns json language plpgsql security definer set search_path=public as $$
declare s settings; sold int; canc int;
begin
  if auth.uid() is null then raise exception 'unauthorized'; end if;
  select * into s from settings where id=1;
  select coalesce(sum(qty),0) into sold from orders where status='confirmed';
  select coalesce(sum(qty),0) into canc from orders where status='cancelled';
  return json_build_object('total',s.total,'sale_limit',s.sale_limit,'personal',s.personal,'reserve',s.reserve,
    'booked',sold,'cancelled',canc,'remaining',s.sale_limit-sold,
    'acceptable',case when s.booking_open then s.sale_limit-sold else 0 end,
    'open',s.booking_open,'special',s.special_round,'low',(s.sale_limit-sold)<=s.low_alert);
end $$;

create function admin_cancel(p_code text) returns json language plpgsql security definer set search_path=public as $$
declare o orders;
begin
  if auth.uid() is null then raise exception 'unauthorized'; end if;
  perform 1 from settings where id=1 for update;
  select * into o from orders where code=upper(trim(p_code)) and status='confirmed';
  if not found then return json_build_object('ok',false); end if;
  update orders set status='cancelled',cancelled_at=now() where id=o.id;  -- ไม่ลบแถว
  insert into stock_logs(order_id,code,action,qty_change) values(o.id,o.code,'CANCEL_RETURN',-o.qty);
  return json_build_object('ok',true);
end $$;

create function admin_set_open(p_open boolean,p_special boolean) returns json
language plpgsql security definer set search_path=public as $$
declare s settings; sold int;
begin
  if auth.uid() is null then raise exception 'unauthorized'; end if;
  select * into s from settings where id=1 for update;
  select coalesce(sum(qty),0) into sold from orders where status='confirmed';
  if p_open and sold>=s.sale_limit then return json_build_object('ok',false,'error','NO_STOCK'); end if;
  update settings set booking_open=p_open,special_round=(p_open and p_special) where id=1;
  insert into stock_logs(action,qty_change) values(case when p_open then 'OPEN_SPECIAL' else 'CLOSE' end,0);
  return json_build_object('ok',true);
end $$;
