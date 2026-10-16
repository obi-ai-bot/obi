import { Group, Row, SettingsPage } from './SettingsView';

export const knowledgeLabel = 'Knowledge';

// An Obysphere's knowledge, a page of its own (Knowledge, in the side panel): the sources its Obys
// share. They come with #495 (the Sphere picks them, each member signs in); until then there are
// none, and the page says so. Shown only with "Show screens still being built".
export default function KnowledgeView(frame: {
  leaving: boolean;
  covered?: boolean;
  onClose: () => void;
  onGone: () => void;
}) {
  return (
    <SettingsPage title={knowledgeLabel} {...frame}>
      <Group i={1} footer="An Obysphere's knowledge sources (Tetrix, or any graph or vector database with an MCP server) come with #495.">
        <Row label={<span className="set-none">No knowledge sources yet</span>} />
      </Group>
    </SettingsPage>
  );
}
