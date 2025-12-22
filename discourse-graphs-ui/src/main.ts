import './styles/main.css';
import ForceGraph, { ForceGraphInstance, NodeObject, LinkObject } from 'force-graph';
import * as d3 from 'd3';
import { WebSocketClient } from './websocket/WebSocketClient';
import { ColorManager } from './graph/ColorManager';
import { FilterManager } from './graph/FilterManager';
import { PanelManager } from './ui/PanelManager';
import { Node, Link, GraphData } from './types';

class DiscourseGraphsUI {
  private ws: WebSocketClient;
  private graph!: ForceGraphInstance;
  private colorManager: ColorManager;
  private filterManager: FilterManager;
  private panelManager: PanelManager;
  
  private allNodes: Node[] = [];
  private allLinks: Link[] = [];
  private highlightNodes = new Set<Node>();
  private highlightLinks = new Set<Link>();
  private primaryHighlightNode: Node | null = null;
  private currentSelectedNode: Node | null = null;
  private isSidebarCollapsed = false;

  constructor() {
    this.colorManager = new ColorManager();
    this.filterManager = new FilterManager();
    this.panelManager = new PanelManager();
    this.ws = new WebSocketClient('ws://localhost:35904');
    
    this.initTheme();
    this.initGraph();
    this.setupWebSocket();
    this.setupEventListeners();
    this.setupKeyboardShortcuts();
  }

  private initGraph(): void {
    const container = document.getElementById('graph')!;
    const isLight = document.body.classList.contains('light-theme');
    const bgColor = isLight ? '#ffffff' : '#0a0e17';
    
    this.graph = ForceGraph()(container)
      .backgroundColor(bgColor)
      .nodeRelSize(8)
      .nodeCanvasObject((node: NodeObject, ctx: CanvasRenderingContext2D, globalScale: number) => 
        this.renderNode(node as Node, ctx, globalScale))
      .onRenderFramePost((ctx: CanvasRenderingContext2D, globalScale: number) => 
        this.renderPrimaryNodeLabel(ctx, globalScale))
      .linkCanvasObject((link: LinkObject, ctx: CanvasRenderingContext2D, globalScale: number) => 
        this.renderLink(link as Link, ctx, globalScale))
      .linkDirectionalParticles((link: LinkObject) => 
        this.highlightLinks.has(link as Link) ? 4 : 2)
      .linkDirectionalParticleSpeed(0.004)
      .linkDirectionalParticleWidth((link: LinkObject) => 
        this.highlightLinks.has(link as Link) ? 3 : 2)
      .linkDirectionalParticleColor((link: LinkObject) => 
        this.colorManager.getLinkColor((link as Link).type))
      .onNodeHover((node: NodeObject | null) => 
        this.handleNodeHover(node as Node | null))
      .onNodeClick((node: NodeObject) => 
        this.handleNodeClick(node as Node))
      .onNodeRightClick((node: NodeObject) => 
        this.handleNodeRightClick(node as Node))
      .onNodeDragEnd((node: NodeObject) => {
        // Keep node at dragged position temporarily (like before)
        const n = node as Node;
        n.fx = n.x;
        n.fy = n.y;
        
        // After a short delay, release to allow gentle settling in place
        setTimeout(() => {
          n.fx = null;
          n.fy = null;
        }, 100);
      })
      .d3VelocityDecay(0.3)  // Back to original value
      .cooldownTicks(100)
      .warmupTicks(50);
  }

  private renderNode(node: Node, ctx: CanvasRenderingContext2D, globalScale: number): void {
    const fontSize = 14 / globalScale;
    ctx.font = `400 ${fontSize}px Inter, sans-serif`;  // Normal weight for non-selected nodes
    
    const nodeR = Math.sqrt(Math.max(0, node.val || 1)) * 3;
    const isPrimary = node === this.primaryHighlightNode;
    const isSecondary = this.highlightNodes.has(node) && !isPrimary;
    
    // Detect current theme
    const isLightTheme = document.body.classList.contains('light-theme');
    
    let nodeColor: string;
    let textColor: string;
    
    if (isPrimary) {
      nodeColor = this.colorManager.getNodeColor(node.type);
      textColor = '#ffffff';
      
      // Glow effect
      ctx.beginPath();
      ctx.arc(node.x!, node.y!, nodeR * 2.5, 0, 2 * Math.PI);
      const gradient = ctx.createRadialGradient(node.x!, node.y!, nodeR, node.x!, node.y!, nodeR * 2.5);
      gradient.addColorStop(0, nodeColor + '80');
      gradient.addColorStop(1, nodeColor + '00');
      ctx.fillStyle = gradient;
      ctx.fill();
    } else if (isSecondary) {
      nodeColor = this.colorManager.getNodeColor(node.type);
      textColor = isLightTheme ? '#1f2937' : '#e4e7eb';
      
      // Secondary glow
      ctx.beginPath();
      ctx.arc(node.x!, node.y!, nodeR * 1.4, 0, 2 * Math.PI);
      const gradient = ctx.createRadialGradient(node.x!, node.y!, nodeR, node.x!, node.y!, nodeR * 1.4);
      gradient.addColorStop(0, nodeColor + '40');
      gradient.addColorStop(1, nodeColor + '00');
      ctx.fillStyle = gradient;
      ctx.fill();
    } else {
      nodeColor = this.colorManager.getNodeColorDim(node.type);
      textColor = isLightTheme ? '#6b7280' : '#6b7280';
    }
    
    // Draw node
    ctx.beginPath();
    ctx.arc(node.x!, node.y!, nodeR, 0, 2 * Math.PI);
    ctx.fillStyle = nodeColor;
    ctx.fill();
    
    // Primary node border
    if (isPrimary) {
      ctx.strokeStyle = isLightTheme ? '#1f2937' : '#ffffff';
      ctx.lineWidth = 3 / globalScale;
      ctx.stroke();
    }
    
    // Labels - only show for highlighted nodes OR at high zoom
    const showLabel = isPrimary || isSecondary || globalScale >= 1.5;
    
    if (showLabel && !isPrimary) {
      const label = node.title;
      const textY = node.y! + nodeR + fontSize + 4;
      
      // Theme-aware shadow
      if (isLightTheme) {
        // Light theme: subtle light shadow
        ctx.shadowColor = 'rgba(255, 255, 255, 0.9)';
        ctx.shadowBlur = 8;
        ctx.shadowOffsetX = 0;
        ctx.shadowOffsetY = 0;
      } else {
        // Dark theme: strong dark shadow
        ctx.shadowColor = 'rgba(0, 0, 0, 0.9)';
        ctx.shadowBlur = 6;
        ctx.shadowOffsetX = 0;
        ctx.shadowOffsetY = 2;
      }
      
      // Draw text
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = textColor;
      ctx.fillText(label, node.x!, textY);
      
      // Reset shadow
      ctx.shadowColor = 'transparent';
      ctx.shadowBlur = 0;
      ctx.shadowOffsetX = 0;
      ctx.shadowOffsetY = 0;
    }
  }

  private renderPrimaryNodeLabel(ctx: CanvasRenderingContext2D, globalScale: number): void {
    if (!this.primaryHighlightNode) return;
    
    const node = this.primaryHighlightNode;
    const fontSize = 12 / globalScale;
    const nodeR = Math.sqrt(Math.max(0, node.val || 1)) * 4;
    
    ctx.font = `700 ${fontSize}px Inter, sans-serif`;  // Bold for selected node
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#ffffff';
    
    ctx.shadowColor = 'rgba(0, 0, 0, 0.8)';
    ctx.shadowBlur = 4;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 1;
    
    ctx.fillText(node.title, node.x!, node.y! + nodeR + fontSize + 2);
    
    ctx.shadowColor = 'transparent';
    ctx.shadowBlur = 0;
  }

  private renderLink(link: Link, ctx: CanvasRenderingContext2D, _globalScale: number): void {
    const start = link.source as Node;
    const end = link.target as Node;
    
    if (!start.x || !start.y || !end.x || !end.y) return;
    
    const isHighlight = this.highlightLinks.has(link);
    const color = isHighlight 
      ? this.colorManager.getLinkColor(link.type)
      : this.colorManager.getLinkColorDim(link.type);
    const opacity = isHighlight ? '' : '60';
    
    // Draw link line
    ctx.strokeStyle = color + opacity;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(start.x, start.y);
    ctx.lineTo(end.x, end.y);
    ctx.stroke();
    
    // Calculate arrow position
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const angle = Math.atan2(dy, dx);
    const nodeR = 8;
    
    const arrowX = end.x - Math.cos(angle) * nodeR;
    const arrowY = end.y - Math.sin(angle) * nodeR;
    
    // Draw arrow
    const arrowLength = 5;
    ctx.fillStyle = color + opacity;
    ctx.beginPath();
    ctx.moveTo(arrowX, arrowY);
    ctx.lineTo(
      arrowX - arrowLength * Math.cos(angle - Math.PI / 5),
      arrowY - arrowLength * Math.sin(angle - Math.PI / 5)
    );
    ctx.lineTo(
      arrowX - arrowLength * Math.cos(angle + Math.PI / 5),
      arrowY - arrowLength * Math.sin(angle + Math.PI / 5)
    );
    ctx.closePath();
    ctx.fill();
    
    // Add subtle edge for highlighted links
    if (isHighlight) {
      ctx.beginPath();
      ctx.moveTo(arrowX, arrowY);
      ctx.lineTo(
        arrowX - arrowLength * Math.cos(angle - Math.PI / 5),
        arrowY - arrowLength * Math.sin(angle - Math.PI / 5)
      );
      ctx.lineTo(
        arrowX - arrowLength * Math.cos(angle + Math.PI / 5),
        arrowY - arrowLength * Math.sin(angle + Math.PI / 5)
      );
      ctx.closePath();
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.2)';
      ctx.lineWidth = 0.3;
      ctx.stroke();
    }
  }

  private handleNodeHover(node: Node | null): void {
    this.highlightNodes.clear();
    this.highlightLinks.clear();
    
    if (node) {
      this.highlightNodes.add(node);
      
      this.allLinks.forEach(link => {
        if (link.source === node || link.target === node) {
          this.highlightLinks.add(link);
          this.highlightNodes.add(link.source as Node);
          this.highlightNodes.add(link.target as Node);
        }
      });
    } else {
      // Mouse left all nodes - schedule panel hide
      this.panelManager.scheduleHide(1000);
    }
    
    if (this.primaryHighlightNode) {
      this.highlightNodes.add(this.primaryHighlightNode);
    }
  }

  private handleNodeClick(node: Node): void {
    this.currentSelectedNode = node;
    this.primaryHighlightNode = node;
    this.panelManager.show(node);
  }

  private handleNodeRightClick(node: Node): void {
    this.openNode(node);
  }

  private openNode(node: Node): void {
    if (!this.ws.isConnected()) {
      this.showToast('❌ Not connected to Emacs');
      return;
    }
    
    this.ws.send({
      type: 'open',
      data: { id: node.id }
    });
    
    this.showToast('📂 Opening in Emacs...');
  }

  private setupWebSocket(): void {
    this.ws.on('connected', () => {
      this.updateStatus(true);
    });

    this.ws.on('disconnected', () => {
      this.updateStatus(false);
    });

    this.ws.on('graphdata', (data: GraphData) => {
      this.updateGraphData(data);
    });

    this.ws.on('command', (data: any) => {
      this.handleCommand(data);
    });

    this.ws.connect();
  }

  private updateGraphData(data: GraphData): void {
    this.allNodes = data.nodes.map(node => ({
      ...node,
      val: 1
    }));

    this.allLinks = data.links.map(link => ({
      source: link.source,
      target: link.target,
      type: link.type || 'default'
    }));

    // Build color maps
    this.colorManager.buildColorMaps(this.allNodes, this.allLinks);
    
    // Update filter manager
    this.filterManager.updateTypes(this.allNodes);
    
    // Build filter UI
    this.buildFilterUI();
    
    // Apply filters and render
    this.applyFilters();
  }

  private buildFilterUI(): void {
    const container = document.getElementById('filterItems')!;
    container.innerHTML = '';
    
    const types = Array.from(this.filterManager.getAllTypes()).sort();
    types.forEach(type => {
      const color = this.colorManager.getNodeColor(type);
      
      const label = document.createElement('label');
      label.className = 'filter-item';
      
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = true;
      
      const toggle = document.createElement('div');
      toggle.className = 'filter-toggle';
      
      const dot = document.createElement('div');
      dot.className = 'filter-dot';
      dot.style.background = color;
      
      const labelText = document.createElement('span');
      labelText.className = 'filter-label';
      labelText.textContent = type.charAt(0).toUpperCase() + type.slice(1);
      
      checkbox.addEventListener('change', () => {
        this.filterManager.toggleType(type, checkbox.checked);
        this.applyFilters();
      });
      
      label.appendChild(checkbox);
      label.appendChild(toggle);
      label.appendChild(dot);
      label.appendChild(labelText);
      container.appendChild(label);
    });
  }

  private applyFilters(): void {
    const enabledTypes = this.filterManager.getEnabledTypes();
    const filteredNodes = this.allNodes.filter(n => enabledTypes.has(n.type));
    const nodeIds = new Set(filteredNodes.map(n => n.id));
    const filteredLinks = this.allLinks.filter(l => 
      nodeIds.has((l.source as Node).id || (l.source as string)) &&
      nodeIds.has((l.target as Node).id || (l.target as string))
    );
    
    this.graph.graphData({ nodes: filteredNodes, links: filteredLinks });
    
    // Update stats
    document.getElementById('nodeCount')!.textContent = filteredNodes.length.toString();
    document.getElementById('linkCount')!.textContent = filteredLinks.length.toString();
    
    // Auto-fit view
    if (filteredNodes.length > 0) {
      setTimeout(() => {
        this.graph.zoomToFit(400, 50);
      }, 100);
    }
  }

  private setupEventListeners(): void {
    // Search
    const searchBox = document.getElementById('searchBox') as HTMLInputElement;
    searchBox.addEventListener('input', (e) => {
      this.handleSearch((e.target as HTMLInputElement).value);
    });

    // Physics controls
    const chargeSlider = document.getElementById('chargeSlider') as HTMLInputElement;
    chargeSlider.addEventListener('input', (e) => {
      const value = (e.target as HTMLInputElement).value;
      document.getElementById('chargeValue')!.textContent = value;
      this.graph.d3Force('charge', d3.forceManyBody().strength(-Number(value)));
      this.graph.d3ReheatSimulation();
    });

    const distanceSlider = document.getElementById('distanceSlider') as HTMLInputElement;
    distanceSlider.addEventListener('input', (e) => {
      const value = (e.target as HTMLInputElement).value;
      document.getElementById('distanceValue')!.textContent = value;
      this.graph.d3Force('link').distance(Number(value));
      this.graph.d3ReheatSimulation();
    });

    // Sidebar toggle
    const sidebarToggle = document.getElementById('sidebarToggle')!;
    sidebarToggle.addEventListener('click', () => {
      this.toggleSidebar();
    });

    // Theme toggle
    const themeToggle = document.getElementById('themeToggle')!;
    themeToggle.addEventListener('click', () => {
      this.toggleTheme();
    });

    // Panel open button
    this.panelManager.onOpen((node) => {
      this.openNode(node);
    });

    // Window resize with debounce and re-centering
    let resizeTimeout: number;
    window.addEventListener('resize', () => {
      clearTimeout(resizeTimeout);
      resizeTimeout = window.setTimeout(() => {
        const container = document.getElementById('graph')!;
        
        // Get old dimensions and center
        const oldWidth = this.graph.width();
        const oldHeight = this.graph.height();
        const currentScale = this.graph.zoom();
        const currentCenter = this.graph.centerAt();
        
        // Resize graph
        const newWidth = container.clientWidth;
        const newHeight = container.clientHeight;
        
        this.graph
          .width(newWidth)
          .height(newHeight);
        
        // Calculate offset to keep graph centered
        const widthDiff = newWidth - oldWidth;
        const heightDiff = newHeight - oldHeight;
        const offsetX = widthDiff / 2;
        const offsetY = heightDiff / 2;
        
        // Smoothly pan to keep graph centered in new viewport
        if (currentCenter.x !== undefined && currentCenter.y !== undefined) {
          this.graph.centerAt(
            currentCenter.x - offsetX / currentScale,
            currentCenter.y - offsetY / currentScale,
            300  // 300ms smooth transition
          );
        }
      }, 100);
    });
  }

  private setupKeyboardShortcuts(): void {
    document.addEventListener('keydown', (e) => {
      if (e.key === 'r' || e.key === 'R') {
        if (this.ws.isConnected()) {
          this.ws.send({ type: 'requestGraphData' });
        }
      } else if (e.key === 'Enter' && this.currentSelectedNode) {
        this.openNode(this.currentSelectedNode);
      } else if (e.key === '[' || e.key === ']') {
        this.toggleSidebar();
      } else if (e.key === '/' || (e.key === 'f' && e.ctrlKey)) {
        e.preventDefault();
        // Expand sidebar if collapsed
        if (this.isSidebarCollapsed) {
          this.toggleSidebar();
        }
        (document.getElementById('searchBox') as HTMLInputElement).focus();
      } else if (e.key === '?' || (e.key === 'h' && !e.ctrlKey && !e.metaKey)) {
        this.showHelp();
      }
    });
  }

  private showHelp(): void {
    const helpText = `
🎮 控制说明

鼠标操作：
• 拖动节点 = 调整节点位置
• 拖动空白 = 平移整个图形 ⭐
• 滚轮 = 缩放
• 单击节点 = 选中
• 右键节点 = 在 Emacs 中打开

键盘快捷键：
• / 或 Ctrl+F = 搜索节点
• R = 刷新数据
• [ 或 ] = 切换侧边栏
• Enter = 打开选中节点
• ? 或 H = 显示此帮助

提示：
想移动整个图形到其他位置？
→ 拖动空白区域即可平移画布！
    `.trim();
    
    this.showToast(helpText, 8000);
  }

  private handleSearch(query: string): void {
    if (!query.trim()) {
      this.primaryHighlightNode = null;
      return;
    }
    
    const matches = this.allNodes.filter(n => 
      n.title.toLowerCase().includes(query.toLowerCase())
    );
    
    if (matches.length > 0) {
      this.primaryHighlightNode = matches[0];
      this.currentSelectedNode = matches[0];
      this.centerOnNode(matches[0]);
      this.showToast(`Found: ${matches[0].title.substring(0, 30)}...`);
    } else {
      this.showToast('No matches found');
    }
  }

  private centerOnNode(node: Node, zoom: number = 2.5, duration: number = 1000): void {
    // Calculate sidebar offset for proper centering
    const graphEl = document.getElementById('graph')!;
    const sidebarWidth = this.isSidebarCollapsed ? 0 : 280;
    
    // Calculate actual graph viewport center
    const viewportWidth = graphEl.clientWidth;
    const graphCenterX = viewportWidth / 2;
    
    // No offset needed - graph already accounts for sidebar in its width
    this.graph.centerAt(node.x, node.y, duration);
    this.graph.zoom(zoom, duration);
  }

  private toggleSidebar(): void {
    const sidebar = document.getElementById('sidebar')!;
    const graphEl = document.getElementById('graph')!;
    
    // Determine the shift direction and amount
    const sidebarWidth = 280;
    const wasCollapsed = this.isSidebarCollapsed;
    
    this.isSidebarCollapsed = !this.isSidebarCollapsed;
    
    if (this.isSidebarCollapsed) {
      sidebar.classList.add('collapsed');
    } else {
      sidebar.classList.remove('collapsed');
    }
    
    // Wait for CSS transition, then shift graph
    setTimeout(() => {
      // Resize graph to new dimensions
      this.graph
        .width(graphEl.clientWidth)
        .height(graphEl.clientHeight);
      
      // Get current camera position
      const currentCenter = this.graph.centerAt();
      const currentScale = this.graph.zoom();
      
      // Calculate shift amount in graph coordinates
      // Camera movement is OPPOSITE to visual content movement:
      // - Sidebar opens: camera moves LEFT (x decreases) → content appears to shift RIGHT
      // - Sidebar closes: camera moves RIGHT (x increases) → content appears to shift LEFT
      const shiftDirection = wasCollapsed ? -1 : 1;  // Opening: -1 (left), Closing: +1 (right)
      const shiftAmount = (sidebarWidth / 2) / currentScale;
      
      // Smoothly shift the camera
      if (currentCenter.x !== undefined && currentCenter.y !== undefined) {
        this.graph.centerAt(
          currentCenter.x + (shiftDirection * shiftAmount),
          currentCenter.y,
          500  // 500ms smooth transition
        );
      }
    }, 320);  // Wait for CSS transition (300ms)
  }

  private handleCommand(data: any): void {
    if (data.commandName === 'follow' && data.id) {
      const node = this.allNodes.find(n => n.id === data.id);
      if (node) {
        const indicator = document.getElementById('followIndicator')!;
        indicator.classList.add('active');
        setTimeout(() => {
          indicator.classList.remove('active');
        }, 2000);
        
        this.highlightNodes.clear();
        this.highlightLinks.clear();
        this.primaryHighlightNode = node;
        this.highlightNodes.add(node);
        this.currentSelectedNode = node;
        
        this.centerOnNode(node, 2.5, 1000);
        this.showToast('🎯 Following: ' + node.title.substring(0, 30) + '...');
      }
    }
  }

  private updateStatus(connected: boolean): void {
    const statusEl = document.getElementById('status')!;
    if (connected) {
      statusEl.className = 'status-badge connected';
      statusEl.innerHTML = '<span class="status-dot"></span> Connected';
    } else {
      statusEl.className = 'status-badge disconnected';
      statusEl.innerHTML = '<span class="status-dot"></span> Disconnected';
    }
  }

  private showToast(message: string, duration: number = 2000): void {
    const toast = document.getElementById('toast')!;
    toast.textContent = message;
    toast.style.whiteSpace = 'pre-line';  // Support multi-line messages
    toast.classList.add('visible');
    setTimeout(() => {
      toast.classList.remove('visible');
    }, duration);
  }

  private initTheme(): void {
    // Load theme from localStorage
    const savedTheme = localStorage.getItem('dg-theme');
    if (savedTheme === 'light') {
      document.body.classList.add('light-theme');
    }
  }

  private toggleTheme(): void {
    const isLight = document.body.classList.toggle('light-theme');
    localStorage.setItem('dg-theme', isLight ? 'light' : 'dark');
    
    // Update graph background color
    const bgColor = isLight ? '#ffffff' : '#0a0e17';
    this.graph.backgroundColor(bgColor);
    
    this.showToast(isLight ? 'Switched to Light theme' : 'Switched to Dark theme');
  }
}

// Initialize app
new DiscourseGraphsUI();
console.log('🚀 Discourse Graphs UI started');
