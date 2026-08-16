"use client";

import { useState } from "react";
import Link from "next/link";
import {
  type ColumnDef,
  type SortingState,
  flexRender,
  getCoreRowModel,
  getPaginationRowModel,
  getSortedRowModel,
  useReactTable,
} from "@tanstack/react-table";
import { ArrowUp, ArrowDown, ArrowUpDown, ChevronLeft, ChevronRight, Eye, Pencil } from "lucide-react";
import { cn } from "@/lib/utils";
import { DeleteRowButton } from "@/components/ui/delete-row-button";

// Server Components may render arbitrary closures (column cell renderers,
// href builders) freely, but a Client Component boundary can only receive
// serializable data or genuine "use server" action references -- not plain
// functions. So DataTable (server) pre-renders every cell to a ReactNode
// and resolves every href/action per row *before* handing off to this
// client component, which only ever touches already-serializable props.
export type RenderedCell = { node: React.ReactNode; sortValue?: unknown };
export type RenderedColumn = { header: string; className?: string; sortable: boolean };
export type RenderedRow = {
  id: string;
  cells: RenderedCell[];
  detailHref?: string;
  deleteAction?: () => Promise<void>;
};

export function DataTableClient({
  columns,
  rows,
  pageSize = 10,
}: {
  columns: RenderedColumn[];
  rows: RenderedRow[];
  pageSize?: number;
}) {
  const [sorting, setSorting] = useState<SortingState>([]);
  const showActions = rows.some((r) => r.detailHref !== undefined || r.deleteAction !== undefined);

  const columnDefs: ColumnDef<RenderedRow>[] = columns.map((col, idx) => ({
    id: `col-${idx}`,
    accessorFn: (row) => row.cells[idx]?.sortValue,
    enableSorting: col.sortable,
    header: col.header,
    cell: ({ row }) => row.original.cells[idx]?.node,
    meta: { className: col.className },
  }));

  const table = useReactTable({
    data: rows,
    columns: columnDefs,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getPaginationRowModel: getPaginationRowModel(),
    initialState: { pagination: { pageSize } },
  });

  return (
    <div className="overflow-hidden rounded-md border border-desktop-border bg-card shadow-elevation-1">
      <div className="overflow-x-auto">
        <table className="w-full min-w-max border-collapse text-[12.5px]">
          <thead>
            {table.getHeaderGroups().map((headerGroup) => (
              <tr key={headerGroup.id} className="border-b border-desktop-border bg-desktop-muted text-left text-[11px] font-semibold text-muted-foreground">
                {headerGroup.headers.map((header) => {
                  const sortable = header.column.getCanSort();
                  const sortDir = header.column.getIsSorted();
                  return (
                    <th
                      key={header.id}
                      className={cn(
                        "h-7 border-r border-desktop-border px-2.5 font-semibold last:border-r-0",
                        (header.column.columnDef.meta as { className?: string } | undefined)?.className
                      )}
                    >
                      {sortable ? (
                        <button
                          onClick={header.column.getToggleSortingHandler()}
                          className="inline-flex items-center gap-1 transition-colors hover:text-foreground"
                        >
                          {flexRender(header.column.columnDef.header, header.getContext())}
                          {sortDir === "asc" ? (
                            <ArrowUp className="size-3" />
                          ) : sortDir === "desc" ? (
                            <ArrowDown className="size-3" />
                          ) : (
                            <ArrowUpDown className="size-3 opacity-40" />
                          )}
                        </button>
                      ) : (
                        flexRender(header.column.columnDef.header, header.getContext())
                      )}
                    </th>
                  );
                })}
                {showActions && <th className="h-7 px-2.5 text-right font-semibold">Actions</th>}
              </tr>
            ))}
          </thead>
          <tbody>
            {table.getRowModel().rows.map((row, i) => (
              <tr
                key={row.id}
                className={cn(
                  "border-b border-desktop-border transition-colors last:border-0 hover:bg-primary/5",
                  i % 2 === 1 && "bg-desktop-muted/40"
                )}
              >
                {row.getVisibleCells().map((cell) => (
                  <td
                    key={cell.id}
                    className={cn(
                      "h-7 border-r border-desktop-border px-2.5 align-middle last:border-r-0",
                      (cell.column.columnDef.meta as { className?: string } | undefined)?.className
                    )}
                  >
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </td>
                ))}
                {showActions && (
                  <td className="h-7 px-2.5 text-right align-middle">
                    <div className="inline-flex items-center gap-0.5">
                      {row.original.detailHref && (
                        <>
                          <Link
                            href={row.original.detailHref}
                            title="View"
                            className="inline-flex size-6 items-center justify-center rounded-sm text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                          >
                            <Eye className="size-3.5" />
                          </Link>
                          <Link
                            href={row.original.detailHref}
                            title="Edit"
                            className="inline-flex size-6 items-center justify-center rounded-sm text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                          >
                            <Pencil className="size-3.5" />
                          </Link>
                        </>
                      )}
                      {row.original.deleteAction && <DeleteRowButton action={row.original.deleteAction} />}
                    </div>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex items-center justify-between border-t border-desktop-border bg-desktop-muted px-2.5 py-1">
        <p className="text-[11px] text-muted-foreground">
          {rows.length} row{rows.length === 1 ? "" : "s"}
          {table.getPageCount() > 1 && (
            <>
              {" "}
              &middot; Page {table.getState().pagination.pageIndex + 1} of {table.getPageCount()}
            </>
          )}
        </p>
        {table.getPageCount() > 1 && (
          <div className="flex items-center gap-1">
            <button
              onClick={() => table.previousPage()}
              disabled={!table.getCanPreviousPage()}
              className="inline-flex size-6 items-center justify-center rounded-sm text-muted-foreground transition-colors hover:bg-muted hover:text-foreground disabled:pointer-events-none disabled:opacity-40"
            >
              <ChevronLeft className="size-3.5" />
            </button>
            <button
              onClick={() => table.nextPage()}
              disabled={!table.getCanNextPage()}
              className="inline-flex size-6 items-center justify-center rounded-sm text-muted-foreground transition-colors hover:bg-muted hover:text-foreground disabled:pointer-events-none disabled:opacity-40"
            >
              <ChevronRight className="size-3.5" />
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
