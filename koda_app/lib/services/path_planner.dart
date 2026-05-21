import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'slam_service.dart';

class _Node implements Comparable<_Node> {
  final int x;
  final int y;
  final double gCost; // Cost from start
  final double hCost; // Heuristic cost to goal
  final _Node? parent;

  _Node(this.x, this.y, this.gCost, this.hCost, this.parent);

  double get fCost => gCost + hCost;

  @override
  int compareTo(_Node other) {
    int cmp = fCost.compareTo(other.fCost);
    if (cmp == 0) {
      cmp = hCost.compareTo(other.hCost);
    }
    return cmp;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _Node && runtimeType == other.runtimeType && x == other.x && y == other.y;

  @override
  int get hashCode => x.hashCode ^ y.hashCode;
}

class PathPlanner {
  /// The maximum cost allowed for a cell to be traversable.
  /// Costmap is 0-254. 254 is lethal obstacle.
  static const int lethalCost = 250;

  /// Find a path using A* from startMm to goalMm
  static List<Offset> planPath(OccupancyGrid grid, Offset startMm, Offset goalMm) {
    int startX = _toCell(startMm.dx);
    int startY = _toCell(startMm.dy);
    int goalX = _toCell(goalMm.dx);
    int goalY = _toCell(goalMm.dy);

    if (!_isValid(grid, goalX, goalY)) return [];
    if (!_isValid(grid, startX, startY)) return [];

    // Priority Queue for Open Set
    final openSet = PriorityQueue<_Node>();
    final openMap = <int, _Node>{}; // Fast lookup: key = y * kGridSize + x
    final closedSet = <int>{};

    final startNode = _Node(startX, startY, 0, _heuristic(startX, startY, goalX, goalY), null);
    openSet.add(startNode);
    openMap[_hash(startX, startY)] = startNode;

    // 8-way movement: dx, dy, cost
    final moves = [
      [0, -1, 1.0], [0, 1, 1.0], [-1, 0, 1.0], [1, 0, 1.0], // Straight
      [-1, -1, 1.414], [1, -1, 1.414], [-1, 1, 1.414], [1, 1, 1.414] // Diagonal
    ];

    int iterations = 0;
    const maxIterations = 50000; // Failsafe to prevent infinite loops

    while (openSet.isNotEmpty && iterations < maxIterations) {
      iterations++;
      final current = openSet.removeFirst();
      openMap.remove(_hash(current.x, current.y));

      if (current.x == goalX && current.y == goalY) {
        return _reconstructPath(current);
      }

      closedSet.add(_hash(current.x, current.y));

      for (var m in moves) {
        int nx = current.x + (m[0] as int);
        int ny = current.y + (m[1] as int);
        double moveCost = m[2] as double;

        if (!_isValid(grid, nx, ny)) continue;
        if (closedSet.contains(_hash(nx, ny))) continue;

        // Add a penalty based on the costmap to keep the robot away from walls
        // A costmap value of 200 adds ~4.0 extra cost per step, heavily discouraging it.
        double penalty = (grid.costmapCells[ny][nx] / 50.0);
        double tentativeG = current.gCost + moveCost + penalty;

        final neighborHash = _hash(nx, ny);
        var neighbor = openMap[neighborHash];

        if (neighbor == null || tentativeG < neighbor.gCost) {
          final h = _heuristic(nx, ny, goalX, goalY);
          final newNode = _Node(nx, ny, tentativeG, h, current);
          
          if (neighbor != null) {
             // PriorityQueue doesn't have a fast update, so we just remove and re-add
             openSet.remove(neighbor);
          }
          openSet.add(newNode);
          openMap[neighborHash] = newNode;
        }
      }
    }

    return []; // No path found
  }

  static bool _isValid(OccupancyGrid grid, int x, int y) {
    if (x < 0 || x >= kGridSize || y < 0 || y >= kGridSize) return false;
    // Don't drive through unknown (-1) or lethal obstacles
    if (grid.cells[y][x] == -1) return false;
    if (grid.costmapCells[y][x] >= lethalCost) return false;
    if (grid.cells[y][x] >= 50) return false;
    return true;
  }

  static double _heuristic(int x1, int y1, int x2, int y2) {
    // Euclidean distance
    int dx = x1 - x2;
    int dy = y1 - y2;
    return math.sqrt(dx * dx + dy * dy);
  }

  static int _hash(int x, int y) => y * kGridSize + x;

  static int _toCell(double mm) => (kOriginCell + mm / kCellSizeMm).round().clamp(0, kGridSize - 1);
  static double _toMm(int cell) => (cell - kOriginCell) * kCellSizeMm.toDouble();

  static List<Offset> _reconstructPath(_Node endNode) {
    final path = <Offset>[];
    _Node? current = endNode;
    while (current != null) {
      path.add(Offset(_toMm(current.x), _toMm(current.y)));
      current = current.parent;
    }
    return path.reversed.toList();
  }
}
