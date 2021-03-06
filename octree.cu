#include <cstdlib>
#include <iostream>
#include "octree.h"

#define COORD_MAX 40.0f
#define COORD_MIN -40.0f

FLOAT3 * unc_pos;
FLOAT3 * dev_buffer1;
FLOAT3 * dev_buffer2;
__device__ Octree_node * all_nodes;
__device__ int num_nodes;
const int THREADS_PER_BLOCK = 128;
const int shared_mem = 16*sizeof(int);

__host__ static __inline__ void rnd()
{
  for (int i = 0; i < nbody; i++) {
    unc_pos[i].x = COORD_MIN + (rand() / ( RAND_MAX / (COORD_MAX-COORD_MIN) ) ) ;
    unc_pos[i].y = COORD_MIN + (rand() / ( RAND_MAX / (COORD_MAX-COORD_MIN) ) ) ;
    unc_pos[i].z = COORD_MIN + (rand() / ( RAND_MAX / (COORD_MAX-COORD_MIN) ) ) ;
  }
}

__device__ bool check_points(Octree_node &node, FLOAT3 *points1, FLOAT3 *points2, int num_points, Parameters params){
  if(params.depth >= params.max_depth || num_points <= params.min_points){
    if(params.point_selector == 1){
      int it = node.points_begin(); int end = node.points_end();
      for(it += threadIdx.x; it < end; it += blockDim.x){
        points1[it] = points2[it];
      }
    }
    return true;
  }
  return false;
}

__device__ void count_points(const FLOAT3 *in_points, int *smem, int range_begin, int range_end, FLOAT3 center){
  if(threadIdx.x < 8) smem[threadIdx.x] = 0;
  __syncthreads();

  for(int iter=range_begin+threadIdx.x; iter<range_end; iter+=blockDim.x){
    FLOAT3 p = in_points[iter];

    int x = p.x < center.x ? 0 : 1;
    int y = p.y < center.y ? 0 : 1;
    int z = p.z < center.z ? 0 : 1;

    int i = x*4 + y*2 + z;

    atomicAdd(&smem[i], 1);
  }
  __syncthreads();
}

__device__ void scan_offsets(int node_points_begin, int* smem){
  int *smem2 = &smem[8];
  if(threadIdx.x == 0){
    for(int i = 0; i < 8; i++){
      smem2[i] = i == 0 ? 0 : smem2[i-1] + smem[i-1];
    }
    for (int i = 0; i < 8; i++){
      smem2[i] += node_points_begin;
    }
  }
  __syncthreads();
}

__device__ void reorder_points(FLOAT3 *out_points, const FLOAT3 *in_points, int *smem, int range_begin, int range_end, FLOAT3 center){
  int *smem2 = &smem[8];

  for(int iter = range_begin+threadIdx.x; iter<range_end; iter+=blockDim.x){
    FLOAT3 p = in_points[iter];

    int x = p.x < center.x ? 0 : 1;
    int y = p.y < center.y ? 0 : 1;
    int z = p.z < center.z ? 0 : 1;

    int i = x*4 + y*2 + z;

    int dest = atomicAdd(&smem2[i], 1);
    out_points[dest] = p;
  }

  __syncthreads();
}

__device__ void prepare_children(Octree_node *children, Octree_node &node, int *smem){

  const FLOAT3 center = node.center();
  float half = node.width() / 2.0f;
  float quarter = half / 2.0f;
  smem[7] = node.points_begin();

  for(int i = 0; i < 8; i++){
    int xf, yf, zf;
    zf = i % 2;
    if (zf == 0) zf = -1;

    yf = (i / 2) % 2;
    if (yf == 0) yf = -1;

    xf = i / 4;
    if (xf == 0) xf = -1;

    children[i].set_center(center.x + quarter * xf,
                           center.y + quarter * yf,
                           center.z + quarter * zf);
    children[i].set_width(half);
    children[i].set_range(smem[7+i], smem[8+i]);
  }
}

__global__ void build_octree_kernel(Octree_node *nodes, FLOAT3 *points1, FLOAT3 *points2, Parameters params){
  __shared__ int smem[16];

  Octree_node &node = nodes[blockIdx.x];
  int num_points = node.num_points();

  bool exit = check_points(node, points1, points2, num_points, params);
  if(exit) return;

  float3 center = node.center();

  int range_begin = node.points_begin();
  int range_end = node.points_end();

  const FLOAT3* in_points = params.point_selector == 0 ? points1 : points2;
  FLOAT3 *out_points = params.point_selector == 0 ? points2 : points1;

  count_points(in_points, smem, range_begin, range_end, center);

  scan_offsets(node.points_begin(), smem);

  reorder_points(out_points, in_points, smem, range_begin, range_end, center);

  if(threadIdx.x == blockDim.x-1){
    int next_node = atomicAdd(&num_nodes, 8);
    node.set_children(next_node);
    Octree_node *children = &all_nodes[next_node];
    prepare_children(children, node, smem);
    build_octree_kernel<<<8, blockDim.x, 16*sizeof(int)>>>(children, points1, points2, Parameters(params, true));
  }
}

__global__ void init_nodes(Octree_node *nodes){
  num_nodes = 1;
  all_nodes = nodes;
}

int main(){

  unc_pos = new FLOAT3[nbody];
  Octree_node *dev_nodes;
  rnd();

  cudaMalloc((void**) &dev_buffer1, nbody*sizeof(FLOAT3));
  cudaMalloc((void**) &dev_buffer2, nbody*sizeof(FLOAT3));
  cudaMemcpy(dev_buffer1, unc_pos, nbody*sizeof(FLOAT3), cudaMemcpyHostToDevice);

  Octree_node root;
  root.set_range(0, nbody);
  root.set_width(2*COORD_MAX);
  cudaMalloc((void **)&dev_nodes, nbody*sizeof(Octree_node));
  cudaMemcpy(dev_nodes, &root, sizeof(Octree_node), cudaMemcpyHostToDevice);

  init_nodes<<<1, 1>>>(dev_nodes);

  Parameters params(nbody);
  //build_octree_kernel<<<1, THREADS_PER_BLOCK, shared_mem>>>(dev_nodes, dev_buffer1, dev_buffer2, params);
  cudaGetLastError();

  FLOAT3 * out = new FLOAT3[nbody];
  cudaMemcpy(out, dev_buffer1, nbody*sizeof(FLOAT3), cudaMemcpyDeviceToHost);

  for (int i = 0; i < nbody; i++) {
    std::cout << unc_pos[i].x << " " << unc_pos[i].y << " " << unc_pos[i].z<< " -- " << out[i].x << " " << out[i].y << " " << out[i].z << '\n';
  }

  cudaFree(dev_nodes);
  cudaFree(dev_buffer1);
  cudaFree(dev_buffer2);

}
