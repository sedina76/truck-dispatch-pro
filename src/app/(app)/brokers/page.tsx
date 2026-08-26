import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";
import { BrokerActions } from "@/components/brokers/broker-actions";

type Row={id:string;legal_name:string;dba_name:string|null;mc_number:string|null;status:string;archived_at:string|null;updated_at:string;primary:string|null;email:string|null;credit_status:string|null;open_loads:number;outstanding:number;last_activity:string|null};
const FILTERS=[['active','Active'],['setup_pending','Setup Pending'],['credit_hold','Credit Hold'],['inactive','Inactive'],['do_not_use','Do Not Use'],['archived','Archived'],['all','All']] as const;
export default async function BrokersPage({searchParams}:{searchParams:Promise<{q?:string;filter?:string}>}){
 const {q,filter='active'}=await searchParams; const supabase=await createClient(); const {data:roleData}=await supabase.rpc('current_role'); const role=(roleData as OrgRole|null)??'viewer'; const financial=FINANCIAL_ROLES.includes(role); const canManage=role==='owner'||role==='admin';
 let query=supabase.from('brokers').select('id,legal_name,dba_name,mc_number,status,archived_at,updated_at').order('legal_name');
 if(filter==='archived') query=query.not('archived_at','is',null); else if(filter!=='all') query=query.is('archived_at',null);
 if(filter==='active') query=query.in('status',['prospect','active']); else if(['setup_pending','inactive','do_not_use'].includes(filter)) query=query.eq('status',filter);
 if(q){
  // Contact name/email match any contact type (not just the primary
  // general one shown in the list column) and are resolved to broker ids
  // first -- RLS on broker_contacts already scopes this to the caller's
  // own organization, so no explicit organization_id filter is needed and
  // no foreign-org contact can ever contribute an id here.
  const {data:matchingContacts}=await supabase.from('broker_contacts').select('broker_id').or(`name.ilike.%${q}%,email.ilike.%${q}%`);
  const contactBrokerIds=Array.from(new Set((matchingContacts??[]).map(c=>c.broker_id)));
  const orParts=[`legal_name.ilike.%${q}%`,`company_name.ilike.%${q}%`,`dba_name.ilike.%${q}%`,`mc_number.ilike.%${q}%`,`dot_number.ilike.%${q}%`,`email.ilike.%${q}%`];
  if(contactBrokerIds.length) orParts.push(`id.in.(${contactBrokerIds.join(',')})`);
  query=query.or(orParts.join(','));
 }
 const {data:base}=await query; const ids=(base??[]).map(x=>x.id);
 const [{data:contacts},{data:loads},{data:invoices},{data:fin},{data:activities}]=await Promise.all([
  ids.length?supabase.from('broker_contacts').select('broker_id,name,email').in('broker_id',ids).eq('is_primary',true).eq('contact_type','general'):Promise.resolve({data:[]}),
  ids.length?supabase.from('loads').select('broker_id,status').in('broker_id',ids):Promise.resolve({data:[]}),
  financial&&ids.length?supabase.from('invoices').select('broker_id,balance_due').in('broker_id',ids).gt('balance_due',0):Promise.resolve({data:[]}),
  financial&&ids.length?supabase.from('broker_financials').select('broker_id,credit_status').in('broker_id',ids):Promise.resolve({data:[]}),
  ids.length?supabase.from('activity_logs').select('entity_id,created_at').eq('entity_type','broker').in('entity_id',ids).order('created_at',{ascending:false}):Promise.resolve({data:[]}),
 ]);
 const rows:Row[]=(base??[]).map(b=>{const c=(contacts??[]).find(x=>x.broker_id===b.id);return {...b,primary:c?.name??null,email:c?.email??null,credit_status:(fin??[]).find(x=>x.broker_id===b.id)?.credit_status??null,open_loads:(loads??[]).filter(x=>x.broker_id===b.id&&!['delivered','cancelled'].includes(x.status)).length,outstanding:(invoices??[]).filter(x=>x.broker_id===b.id).reduce((s,x)=>s+Number(x.balance_due),0),last_activity:(activities??[]).find(x=>x.entity_id===b.id)?.created_at??b.updated_at};});
 const visibleRows=filter==='credit_hold'?rows.filter(x=>x.credit_status==='hold'):rows;
 const columns:Column<Row>[]=[{header:'Broker',cell:r=><div className="min-w-0 max-w-55 wrap-break-word"><span className="font-medium">{r.legal_name}</span>{r.dba_name&&<span className="block text-[11px] text-muted-foreground">{r.dba_name}</span>}</div>,sortKey:'legal_name'},{header:'MC',cell:r=>r.mc_number??'--'},{header:'Primary Contact',cell:r=><div className="min-w-0 max-w-50 wrap-break-word">{r.primary??'--'}{r.email&&<span className="block text-[11px] text-muted-foreground">{r.email}</span>}</div>},{header:'Status',cell:r=><StatusBadge status={r.archived_at?'archived':r.status}/>},...(financial?[{header:'Credit Status',cell:(r:Row)=><StatusBadge status={r.credit_status??'review'}/>}]:[]),{header:'Open Loads',cell:r=>r.open_loads},...(financial?[{header:'Outstanding',cell:(r:Row)=>`$${r.outstanding.toLocaleString()}`}]:[]),{header:'Last Activity',cell:r=>r.last_activity?new Date(r.last_activity).toLocaleDateString():'--'},{header:'Actions',cell:r=><BrokerActions id={r.id} name={r.legal_name} archived={Boolean(r.archived_at)} canManage={canManage}/>}];
 return <div className="space-y-3"><DesktopWorkspaceTabs tabs={[{label:'Brokers',href:'/brokers'}]}/><PageHeader title="Brokers" description="Manage broker operations, contacts, credit health, and relationship history." primaryAction={{label:'Add Broker',href:'/brokers/new'}}/><DesktopKpiStrip><DesktopKpiBox label="Visible Brokers" value={visibleRows.length}/><DesktopKpiBox label="Setup Pending" value={visibleRows.filter(x=>x.status==='setup_pending').length}/><DesktopKpiBox label="Credit Holds" value={visibleRows.filter(x=>x.credit_status==='hold').length} tone="warning"/><DesktopKpiBox label="Do Not Use" value={visibleRows.filter(x=>x.status==='do_not_use').length} tone="danger"/></DesktopKpiStrip><div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"><SearchBar placeholder="Search name, DBA, MC, DOT, contact, or email…"/><div className="flex max-w-full gap-1 overflow-x-auto pb-1">{FILTERS.map(([v,l])=><Link key={v} href={`/brokers?filter=${v}${q?`&q=${encodeURIComponent(q)}`:''}`} className={`whitespace-nowrap rounded-md border px-2.5 py-1.5 text-xs ${filter===v?'bg-primary text-primary-foreground':'bg-card'}`}>{l}</Link>)}</div></div>{visibleRows.length?<DataTable columns={columns} rows={visibleRows} getDetailHref={r=>`/brokers/${r.id}`}/>:<EmptyState title="No brokers match this view" description="Adjust the search or filter, or add a broker." action={{label:'Add Broker',href:'/brokers/new'}}/>}</div>;
}
