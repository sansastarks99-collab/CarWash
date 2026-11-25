-- Jalankan SEKALI di Supabase SQL Editor (setelah schema.sql)

-- 1. Kasir tidak boleh membaca data sensitif (laporan, HPP, belanja, staff)
drop policy "read" on staff;
drop policy "read" on products;
drop policy "read" on sales;
drop policy "read" on sale_items;
drop policy "read" on expenses;
create policy "read" on staff for select to authenticated using (id=auth.uid() or my_role() in('manager','pemegang_saham'));
create policy "read" on products for select to authenticated using (my_role() in('manager','pemegang_saham'));
create policy "read" on sales for select to authenticated using (my_role() in('manager','pemegang_saham'));
create policy "read" on sale_items for select to authenticated using (my_role() in('manager','pemegang_saham'));
create policy "read" on expenses for select to authenticated using (my_role() in('manager','pemegang_saham'));

-- 2. Kasir tidak input langsung ke tabel; hanya lewat fungsi create_sale
drop policy "kasir_sales" on sales;
drop policy "kasir_items" on sale_items;
drop policy "kasir_exp" on expenses;

-- 3. Fungsi transaksi: harga, diskon, dan HPP dihitung di server (kasir tidak bisa utak-atik harga)
create or replace function create_sale(p_unit text,p_plate text,p_payment text,p_items jsonb) returns bigint
language plpgsql security definer set search_path=public as $$
declare pl text:=upper(regexp_replace(coalesce(p_plate,''),'\s','','g')); m members; pr products;
        sub numeric:=0; pct numeric:=0; disc numeric; sid bigint; it jsonb;
begin
  if my_role() not in('manager','kasir') then raise exception 'Tidak diizinkan'; end if;
  select * into m from members where plate=pl;
  for it in select * from jsonb_array_elements(p_items) loop
    if (it->>'qty')::int<1 then raise exception 'Qty tidak valid'; end if;
    select * into pr from products where id=(it->>'id')::bigint and unit=p_unit and active;
    if not found then raise exception 'Menu tidak valid'; end if;
    sub:=sub+pr.price*(it->>'qty')::int;
  end loop;
  select coalesce(sum(percent),0) into pct from discounts
   where active and (unit='all' or unit=p_unit) and (kind='umum' or (m.id is not null and kind='member_'||m.type));
  disc:=round(sub*least(pct,100)/100);
  insert into sales(unit,staff_id,member_id,plate,subtotal,discount,total,payment)
   values(p_unit,auth.uid(),m.id,nullif(pl,''),sub,disc,sub-disc,p_payment) returning id into sid;
  insert into sale_items(sale_id,name,price,cost,qty)
   select sid,p.name,p.price,p.cost,(x->>'qty')::int from jsonb_array_elements(p_items) x join products p on p.id=(x->>'id')::bigint;
  return sid;
end $$;
revoke all on function create_sale(text,text,text,jsonb) from public, anon;
grant execute on function create_sale(text,text,text,jsonb) to authenticated;

-- 4. View aman untuk kasir: menu tanpa HPP, riwayat hari ini tanpa HPP
create or replace view v_menu as
  select id,unit,name,price from products where active and my_role() is not null;
create or replace view v_riwayat as
  select s.id,s.unit,s.created_at,s.plate,s.payment,s.total,
    (select string_agg(i.name||' x'||i.qty,', ') from sale_items i where i.sale_id=s.id) as items,
    (select name from staff where id=s.staff_id) as staff_name
  from sales s
  where my_role() is not null
    and s.created_at >= (date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta');
revoke all on v_menu, v_riwayat from anon;
grant select on v_menu, v_riwayat to authenticated;
