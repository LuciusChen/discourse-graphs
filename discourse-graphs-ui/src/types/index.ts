export interface Node {
  id: string;
  title: string;
  type: string;
  file: string;
  pos?: number;
  val: number;
  x?: number;
  y?: number;
  vx?: number;
  vy?: number;
  fx?: number | null;
  fy?: number | null;
}

export interface Link {
  source: Node | string;
  target: Node | string;
  type: string;
  style?: string;  // 'solid' or 'dashed'
}

export interface GraphData {
  nodes: Node[];
  links: Link[];
}

export interface WebSocketMessage {
  type: 'graphdata' | 'theme' | 'command';
  data: any;
}

export interface CommandData {
  commandName: string;
  id?: string;
}

export interface ThemeData {
  colors?: Record<string, string>;
}
