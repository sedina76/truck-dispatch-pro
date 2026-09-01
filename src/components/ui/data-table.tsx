import { DataTableClient, type RenderedRow, type RenderedColumn } from "@/components/ui/data-table-client";

export type Column<T> = {
  header: string;
  cell: (row: T) => React.ReactNode;
  className?: string;
  /** Enables sorting on this column using this key's raw value. */
  sortKey?: keyof T;
};

// Server Component: safe to accept arbitrary closures (cell renderers, href
// builders) as props here, unlike the client table it hands off to. Every
// row is fully rendered to plain ReactNode/string/server-action data before
// crossing into DataTableClient -- see that file's header comment for why.
export function DataTable<T extends { id: string }>({
  columns,
  rows,
  getDetailHref,
  getDeleteAction,
  pageSize = 10,
}: {
  columns: Column<T>[];
  rows: T[];
  getDetailHref?: (row: T) => string;
  getDeleteAction?: (row: T) => (() => Promise<void>) | undefined;
  pageSize?: number;
}) {
  const renderedColumns: RenderedColumn[] = columns.map((col) => ({
    header: col.header,
    className: col.className,
    sortable: Boolean(col.sortKey),
  }));

  const renderedRows: RenderedRow[] = rows.map((row) => ({
    id: row.id,
    cells: columns.map((col) => ({
      node: col.cell(row),
      sortValue: col.sortKey ? row[col.sortKey] : undefined,
    })),
    detailHref: getDetailHref?.(row),
    deleteAction: getDeleteAction?.(row),
  }));

  return <DataTableClient columns={renderedColumns} rows={renderedRows} pageSize={pageSize} />;
}
