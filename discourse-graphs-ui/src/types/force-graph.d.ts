declare module 'force-graph' {
  export interface NodeObject {
    id?: string | number;
    x?: number;
    y?: number;
    vx?: number;
    vy?: number;
    fx?: number | null;
    fy?: number | null;
    [key: string]: any;
  }

  export interface LinkObject {
    source: string | number | NodeObject;
    target: string | number | NodeObject;
    [key: string]: any;
  }

  export interface GraphData {
    nodes: NodeObject[];
    links: LinkObject[];
  }

  export interface CenterCoordinates {
    x: number;
    y: number;
  }

  export interface ForceGraphInstance {
    (element: HTMLElement): ForceGraphInstance;
    graphData(): GraphData;  // Getter: returns current graph data
    graphData(data: GraphData): ForceGraphInstance;  // Setter: sets graph data
    backgroundColor(color: string): ForceGraphInstance;
    nodeRelSize(size: number): ForceGraphInstance;
    nodeCanvasObject(fn: (node: NodeObject, ctx: CanvasRenderingContext2D, globalScale: number) => void): ForceGraphInstance;
    onRenderFramePost(fn: (ctx: CanvasRenderingContext2D, globalScale: number) => void): ForceGraphInstance;
    linkCanvasObject(fn: (link: LinkObject, ctx: CanvasRenderingContext2D, globalScale: number) => void): ForceGraphInstance;
    linkDirectionalParticles(value: number | ((link: LinkObject) => number)): ForceGraphInstance;
    linkDirectionalParticleSpeed(speed: number): ForceGraphInstance;
    linkDirectionalParticleWidth(value: number | ((link: LinkObject) => number)): ForceGraphInstance;
    linkDirectionalParticleColor(color: string | ((link: LinkObject) => string)): ForceGraphInstance;
    onNodeHover(fn: (node: NodeObject | null) => void): ForceGraphInstance;
    onNodeClick(fn: (node: NodeObject) => void): ForceGraphInstance;
    onNodeRightClick(fn: (node: NodeObject) => void): ForceGraphInstance;
    onNodeDragEnd(fn: (node: NodeObject) => void): ForceGraphInstance;
    d3Force(forceName: string, force?: any): any;
    d3VelocityDecay(decay: number): ForceGraphInstance;
    d3ReheatSimulation(): ForceGraphInstance;
    cooldownTicks(ticks: number): ForceGraphInstance;
    warmupTicks(ticks: number): ForceGraphInstance;
    
    // Getter/Setter methods
    centerAt(): CenterCoordinates;
    centerAt(x: number, y: number, duration?: number): ForceGraphInstance;
    
    zoom(): number;
    zoom(scale: number, duration?: number): ForceGraphInstance;
    
    zoomToFit(duration?: number, padding?: number): ForceGraphInstance;
    
    width(): number;
    width(width: number): ForceGraphInstance;
    
    height(): number;
    height(height: number): ForceGraphInstance;
  }

  export default function ForceGraph(): ForceGraphInstance;
}
