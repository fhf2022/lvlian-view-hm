export interface MenuPadEvent {
  kind: number;
  code: number;
  down: boolean;
  x: number;
  y: number;
}
export const start: () => number;
export const stop: () => void;
export const capture: (enabled: boolean) => void;
export const read: () => MenuPadEvent[];
