"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Archive, RotateCcw, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { archiveBroker, deleteBroker, restoreBroker } from "@/app/(app)/brokers/actions";

export function BrokerActions({ id, name, archived, canManage }: { id:string; name:string; archived:boolean; canManage:boolean }) {
  const router=useRouter(); const [pending,start]=useTransition(); const [confirmDelete,setConfirmDelete]=useState(false); const [message,setMessage]=useState<string|null>(null);
  if(!canManage) return null;
  const run=(action:()=>Promise<void>)=>start(async()=>{setMessage(null);try{await action();router.refresh();}catch(error){setMessage(error instanceof Error?error.message:"The broker could not be updated.");}});
  return <div className="flex flex-wrap items-center gap-2">
    {archived ? <Button size="sm" variant="outline" disabled={pending} onClick={()=>run(()=>restoreBroker(id))}><RotateCcw className="size-3.5"/> Restore</Button>
      : <Button size="sm" variant="outline" disabled={pending} onClick={()=>run(()=>archiveBroker(id))}><Archive className="size-3.5"/> Archive</Button>}
    <Button size="sm" variant="danger" disabled={pending} onClick={()=>setConfirmDelete(true)}><Trash2 className="size-3.5"/> Delete</Button>
    {message&&<p className="w-full text-xs text-destructive">{message}</p>}
    <Dialog open={confirmDelete} onOpenChange={setConfirmDelete}><DialogContent className="max-w-md"><DialogHeader><DialogTitle>Delete Broker?</DialogTitle><DialogDescription>Are you sure you want to permanently delete {name}? This action cannot be undone.</DialogDescription></DialogHeader>
      <DialogFooter><Button variant="outline" disabled={pending} onClick={()=>setConfirmDelete(false)}>Cancel</Button><Button variant="danger" disabled={pending} onClick={()=>start(async()=>{const result=await deleteBroker(id);if(!result.ok){setMessage(result.error);setConfirmDelete(false);return;}setConfirmDelete(false);router.push("/brokers");router.refresh();})}>{pending?"Deleting…":"Delete Broker"}</Button></DialogFooter>
    </DialogContent></Dialog>
  </div>;
}
