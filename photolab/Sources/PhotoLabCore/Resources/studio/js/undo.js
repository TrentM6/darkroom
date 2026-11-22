// In-session undo / redo (⌘Z / ⇧⌘Z) for marks and edits. Each step knows how to undo and redo itself.
import { toast } from './ui.js';

const done = [], undone = [];
const LIMIT = 200;
const NAMES = { marks: 'mark', edit: 'edit', reset: 'reset', paste: 'paste' };
let busy = false;

export function pushUndo(step) {
  done.push(step);
  if (done.length > LIMIT) done.shift();
  undone.length = 0;
}

async function run(from, to, verb) {
  if (busy) return;
  const step = from.pop();
  if (!step) { toast(`Nothing to ${verb.toLowerCase()}`, { ms: 1400 }); return; }
  busy = true;
  try {
    await (verb === 'Undo' ? step.undo() : step.redo());
    to.push(step);
    toast(`${verb} ${NAMES[step.label] || step.label}`, { ms: 1400 });
  } catch (_) {
    toast(`Couldn't ${verb.toLowerCase()}`);
  } finally { busy = false; }
}
export const undo = () => run(done, undone, 'Undo');
export const redo = () => run(undone, done, 'Redo');
