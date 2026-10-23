/** Rare identity mutations; keep the hot read-only records unchanged. */
export function rekeyRecord<T>(source: Record<string, T>, from: string, to: string): Record<string, T> {
  const result: Record<string, T> = {}
  for (const key of Object.keys(source)) { result[key === from ? to : key] = source[key] }
  return result
}
