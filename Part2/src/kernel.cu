#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include "glm/glm.hpp"
#include "utilities.h"
#include "kernel.h"

#if SHARED == 1
    #define FLOCK(x,y,z,v) sharedMemFlocking(x,y,z,v)
#else
    #define FLOCK(x,y,z,v) navieFlocking(x,y,z,v)
#endif



//GLOBALS
dim3 threadsPerBlock(blockSize);

int numObjects;
int numPredator;
const float planetMass = 3e8;
const __device__ float starMass = 5e10;

const float scene_scale = 2e2; //size of the height map in simulation space

glm::vec4 * dev_pos;
glm::vec3 * dev_vel;

glm::vec4 * pre_pos;
glm::vec3 * pre_vel;

glm::vec3 vWander;
float kWander = 1.0f;

void checkCUDAError(const char *msg, int line = -1)
{
    cudaError_t err = cudaGetLastError();
    if( cudaSuccess != err)
    {
        if( line >= 0 )
        {
            fprintf(stderr, "Line %d: ", line);
        }
        fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
        exit(EXIT_FAILURE); 
    }
} 

__host__ __device__
unsigned int hash(unsigned int a){
    a = (a+0x7ed55d16) + (a<<12);
    a = (a^0xc761c23c) ^ (a>>19);
    a = (a+0x165667b1) + (a<<5);
    a = (a+0xd3a2646c) ^ (a<<9);
    a = (a+0xfd7046c5) + (a<<3);
    a = (a^0xb55a4f09) ^ (a>>16);
    return a;
}

//Function that generates static.
__host__ __device__ 
glm::vec3 generateRandomNumberFromThread(float time, int index)
{
    thrust::default_random_engine rng(hash(index*time));
    thrust::uniform_real_distribution<float> u01(0,1);

    return glm::vec3((float) u01(rng), (float) u01(rng), (float) u01(rng));
}


__global__
void generateRandomPosArray(int time, int N, glm::vec4 * arr, float scale, float mass)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        glm::vec3 rand = scale * (generateRandomNumberFromThread(time + index, index)-0.5f);
        arr[index].x = rand.x;
        arr[index].y = rand.y;
        arr[index].z = rand.z;
        arr[index].w = mass;
    }
}


//Generate randomized starting velocities in the XYZ plane
__global__
void generateRandomVelArray(int time, int N, glm::vec3 * arr, float scale)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        glm::vec3 rand = scale*(generateRandomNumberFromThread(time, index*2 + 1));
        arr[index].x = rand.x;
        arr[index].y = rand.y;
        arr[index].z = rand.z;
    }
}


__device__
glm::vec3 calAlignment(glm::vec3 vel)
{
	return vel;
}

__device__ 
glm::vec3 calSeparation(glm::vec4 d)
{
	glm::vec3 dir;
	dir.x = d.x;
	dir.y = d.y;
	dir.z = d.z;

	float len = dir.x*dir.x + dir.y*dir.y + dir.z*dir.z;
	if(len > DBL_EPSILON)
		return dir/len;
	else
		return glm::vec3(0);
}

__device__
glm::vec3 calCohesion(glm::vec4 them)
{
	return glm::vec3(them);
}


__device__
glm::vec3 navieFlocking(int N, glm::vec4 my_pos, glm::vec4* their_pos, glm::vec3* vel)
{
	glm::vec3 align, separa, cohes;
	int count = 0;
	float totalDist = 0.f;
	float totalMass = 0.f;
	for(int i = 0; i < N; i++)
	{
		glm::vec4 delta = my_pos - their_pos[i];
		float dist = sqrtf(delta.x*delta.x + delta.y*delta.y + delta.z*delta.z);
		if(dist < RNEIGHBOR)
		{
			count ++;
			align += calAlignment(vel[i]) * dist;
			totalDist += dist;
			separa += calSeparation(my_pos - their_pos[i]);
			cohes += calCohesion(their_pos[i]) * their_pos[i].w;
			totalMass += their_pos[i].w;
		}
	}

	totalDist += DBL_EPSILON;
	totalMass += DBL_EPSILON;
	align /= totalDist;
	cohes = cohes / totalMass - glm::vec3(my_pos);

	//if(glm::length(align) < DBL_EPSILON  && glm::length(separa) < DBL_EPSILON && glm::length(cohes) < DBL_EPSILON)
	//	return glm::vec3(10,0,0);

	return (float)ALIGNMENT * align + (float)SEPARATION * separa + (float)COHESION * cohes;
}


//Simple Euler integration scheme
__global__
void updateDroid(int N, float dt, glm::vec4 * pos, glm::vec3 * vel, glm::vec4 * pre_pos, int P)
{
	//extern __shared__ glm::vec4 shPos[blockSize];  
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
	
    if( index < N )
    {
		glm::vec4 my_pos = pos[index];
		float scale = 1;
		int range = RANGE;
		glm::vec3 dir;

		bool isPredator = false;
		for(int i = 0; i < P; i++)
		{
			float len = glm::length(my_pos - pre_pos[i]);
			if(len < RNEIGHBOR*4 && len > DBL_EPSILON)
			{
				dir = glm::normalize(glm::vec3(my_pos) - glm::vec3(pre_pos[i]));
				scale = 10;
				isPredator = true;
				break;
			}
		}

		if(!isPredator){
			if(my_pos.x > range || my_pos.y > range || my_pos.z > range || my_pos.x < -range || my_pos.y < -range || my_pos.z < -range){
				scale = 10;
				dir = glm::normalize(glm::vec3(0,0,0) - glm::vec3(my_pos));
			}
			else{
				dir = FLOCK(N, my_pos, pos, vel);
				if(glm::length(dir) > 2)
					dir = glm::normalize(dir);
				else
					dir = glm::normalize(vel[index]);
			}
		}

		vel[index] = scale * dir * 5.0f;
        pos[index].x += vel[index].x * dt;
        pos[index].y += vel[index].y * dt;
        pos[index].z += vel[index].z * dt;
    }
}

__global__
void updatePredator(int P, float dt, glm::vec4 * pos, glm::vec3 * vel, int time, glm::vec3 vWander)
{
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	
    if( index < P )
    {
		glm::vec4 my_pos = pos[index];
		int range = RANGE;
		glm::vec3 dir;
		float scale = 1;
		if(my_pos.x > range || my_pos.y > range || my_pos.z > range || my_pos.x < -range || my_pos.y < -range || my_pos.z < -range){
			scale = 5;
			glm::vec3 ran = generateRandomNumberFromThread(time, index);
			dir = glm::normalize(glm::vec3(ran.x *scale*scale, ran.y*scale*scale, ran.z *scale*scale) - glm::vec3(my_pos));
		}
		else
		{			
			dir = glm::normalize(vel[index]);
		}
		vel[index] = scale * dir * 10.0f;
		pos[index].x += vel[index].x * dt;
        pos[index].y += vel[index].y * dt;
        pos[index].z += vel[index].z * dt;
	}
}

//Update the vertex buffer object
__global__
void sendToVBO(int N, glm::vec4 * pos, glm::vec3 * vel, float * vbo, float* nbo, int width, int height, float s_scale)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);

    float c_scale_w = -2.0f / s_scale;
    float c_scale_h = -2.0f / s_scale;

    if(index<N)
    {
      	float scale = 3.0f;
		glm::vec3 n;
		if(glm::length(vel[index]) > DBL_EPSILON)
		{
			n = glm::normalize(vel[index]);
		}
		
		glm::vec3 p1,p2,p3,p4;
		p1 = glm::vec3((pos[index].x + 5*scale*n.x)*c_scale_w, (pos[index].y + 5*scale*n.y)*c_scale_h, (pos[index].z + 5*scale*n.z)*c_scale_h);
		p2 = glm::vec3((pos[index].x - scale*n.x - scale)*c_scale_w, (pos[index].y - scale*n.y - scale)*c_scale_h, (pos[index].z - scale*n.z - scale)*c_scale_h);
		p3 = glm::vec3((pos[index].x - scale*n.x + scale)*c_scale_w, (pos[index].y - scale*n.y + scale)*c_scale_h, (pos[index].z - scale*n.z + scale)*c_scale_h);
		p4 = glm::vec3((pos[index].x - scale*n.x + scale)*c_scale_w, (pos[index].y - scale*n.y - scale)*c_scale_h, (pos[index].z - scale*n.z + scale)*c_scale_h);			

		//first
		vbo[48*index+0] = p1.x;
		vbo[48*index+1] = p1.y;
		vbo[48*index+2] = p1.z;
		vbo[48*index+3] = 1;

		vbo[48*index+4] = p2.x;
		vbo[48*index+5] = p2.y;
		vbo[48*index+6] = p2.z;
		vbo[48*index+7] = 1;

		vbo[48*index+8] = p3.x;
		vbo[48*index+9] = p3.y;
		vbo[48*index+10] = p3.z;
		vbo[48*index+11] = 1;

		glm::vec3 n1 = glm::cross(p2-p1, p3 - p1);
		for(int i = 0;i <= 11; i+=4)
		{
			nbo[48*index+i+0] = n1.x; nbo[48*index+i+1] = n1.y; nbo[48*index+i+2] = n1.z; nbo[48*index+i+3] = 0;
		}

		
		//second
		vbo[48*index+12] = p1.x;
		vbo[48*index+13] = p1.y;
		vbo[48*index+14] = p1.z;
		vbo[48*index+15] = 1;

		vbo[48*index+16] = p2.x;
		vbo[48*index+17] = p2.y;
		vbo[48*index+18] = p2.z;
		vbo[48*index+19] = 1;

		vbo[48*index+20] = p4.x;
		vbo[48*index+21] = p4.y;
		vbo[48*index+22] = p4.z;
		vbo[48*index+23] = 1;

		n1 = glm::cross(p2-p1, p4 - p1);
		for(int i = 12;i <= 23; i+=4)
		{
			nbo[48*index+i+0] = n1.x; nbo[48*index+i+1] = n1.y; nbo[48*index+i+2] = n1.z; nbo[48*index+i+3] = 0;
		}

		//third
		vbo[48*index+24] = p1.x;
		vbo[48*index+25] = p1.y;
		vbo[48*index+26] = p1.z;
		vbo[48*index+27] = 1;

		vbo[48*index+28] = p3.x;
		vbo[48*index+29] = p3.y;
		vbo[48*index+30] = p3.z;
		vbo[48*index+31] = 1;

		vbo[48*index+32] = p4.x;
		vbo[48*index+33] = p4.y;
		vbo[48*index+34] = p4.z;
		vbo[48*index+35] = 1;

		n1 = glm::cross(p3-p1, p4 - p1);
		for(int i = 24;i <= 35; i+=4)
		{
			nbo[48*index+i+0] = n1.x; nbo[48*index+i+1] = n1.y; nbo[48*index+i+2] = n1.z; nbo[48*index+i+3] = 0;
		}

		//frouth
		vbo[48*index+36] = p2.x;
		vbo[48*index+37] = p2.y;
		vbo[48*index+38] = p2.z;
		vbo[48*index+39] = 1;

		vbo[48*index+40] = p3.x;
		vbo[48*index+41] = p3.y;
		vbo[48*index+42] = p3.z;
		vbo[48*index+43] = 1;

		vbo[48*index+44] = p4.x;
		vbo[48*index+45] = p4.y;
		vbo[48*index+46] = p4.z;
		vbo[48*index+47] = 1;

		n1 = glm::cross(p3-p2, p4 - p2);
		for(int i = 36;i <= 47; i+=4)
		{
			nbo[48*index+i+0] = n1.x; nbo[48*index+i+1] = n1.y; nbo[48*index+i+2] = n1.z; nbo[48*index+i+3] = 0;
		}
		__syncthreads();
	}
}

//
//__global__
//void sendToVBO(int N, glm::vec4 * pos, glm::vec3 * vel, float * vbo, int width, int height, float s_scale)
//{
//    int index = threadIdx.x + (blockIdx.x * blockDim.x);
//
//    float c_scale_w = -2.0f / s_scale;
//    float c_scale_h = -2.0f / s_scale;
//
//    if(index<N)
//    {
//      	float scale = 2.0f;
//		glm::vec3 n;
//		if(glm::length(vel[index]) > DBL_EPSILON)
//		{
//			n = glm::normalize(vel[index]);
//		}
//		
//		vbo[12*index+0] = (pos[index].x + 5*scale*n.x)*c_scale_w;
//		vbo[12*index+1] = (pos[index].y + 5*scale*n.y)*c_scale_h;
//		vbo[12*index+2] = (pos[index].z + 5*scale*n.z)*c_scale_h;
//		vbo[12*index+3] = 1;
//
//		vbo[12*index+4] = (pos[index].x - scale*n.x - scale)*c_scale_w;
//		vbo[12*index+5] = (pos[index].y - scale*n.y - scale)*c_scale_h;
//		vbo[12*index+6] = (pos[index].z - scale*n.z - scale)*c_scale_h;
//		vbo[12*index+7] = 1;
//
//		vbo[12*index+8] = (pos[index].x - scale*n.x + scale)*c_scale_w;
//		vbo[12*index+9] = (pos[index].y - scale*n.y + scale)*c_scale_h;
//		vbo[12*index+10] = (pos[index].z - scale*n.z + scale)*c_scale_h;
//		vbo[12*index+11] = 1;
//	}
//}


__global__
void sendToVBOPre(int P, glm::vec4 * pos, glm::vec3 * vel, float * vbo, int width, int height, float s_scale)
{
	int index = threadIdx.x + (blockIdx.x * blockDim.x);

    float c_scale_w = -2.0f / s_scale;
    float c_scale_h = -2.0f / s_scale;

    if(index<P)
    {
        vbo[4*index+0] = pos[index].x*c_scale_w;
        vbo[4*index+1] = pos[index].y*c_scale_h;
		vbo[4*index+2] = pos[index].z*c_scale_w;
        vbo[4*index+3] = 1;
    }
}


/*************************************
 * Wrappers for the __global__ calls *
 *************************************/

//Initialize memory, update some globals
void initCuda(int N, int P)
{
    numObjects = N;
	numPredator = P;
    dim3 fullBlocksPerGrid((int)ceil(float(N)/float(blockSize)));

    cudaMalloc((void**)&dev_pos, N*sizeof(glm::vec4));
    checkCUDAErrorWithLine("Kernel failed!");
    cudaMalloc((void**)&dev_vel, N*sizeof(glm::vec3));
    checkCUDAErrorWithLine("Kernel failed!");	

    generateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects, dev_pos, scene_scale, planetMass);
    checkCUDAErrorWithLine("Kernel failed!");

	generateRandomVelArray<<<fullBlocksPerGrid, blockSize>>>(2, numObjects, dev_vel, 5);
	checkCUDAErrorWithLine("Kernel failed!");

	
	fullBlocksPerGrid = dim3((int)ceil(float(P)/float(blockSize)));

	cudaMalloc((void**)&pre_pos, P*sizeof(glm::vec4));
    checkCUDAErrorWithLine("Kernel failed!");
    cudaMalloc((void**)&pre_vel, P*sizeof(glm::vec3));
    checkCUDAErrorWithLine("Kernel failed!");

	generateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(3, numPredator, pre_pos, scene_scale, planetMass);
    checkCUDAErrorWithLine("Kernel failed!");

	generateRandomVelArray<<<fullBlocksPerGrid, blockSize>>>(4, numPredator, pre_vel, 5);
	checkCUDAErrorWithLine("Kernel failed!");

	glm::vec3 ran = generateRandomNumberFromThread(6, P);
	float theta = ran.x * TWO_PI;
	float u = ran.y * 2.f - 1.f;
	vWander = glm::vec3 (cos(theta)*sqrtf(1-u*u), glm::sin(theta)*sqrtf(1-u*u), u) * kWander;
}

void cudaNBodyUpdateWrapper(float dt, int time)
{    
	dim3 fullBlocksPerGrid((int)ceil(float(numPredator)/float(blockSize)));
	updatePredator<<<fullBlocksPerGrid, blockSize>>>(numPredator, dt, pre_pos, pre_vel, time, vWander);
    checkCUDAErrorWithLine("Kernel failed!");
	
	fullBlocksPerGrid = dim3((int)ceil(float(numObjects)/float(blockSize)));
	updateDroid<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel, pre_pos, numPredator);
    checkCUDAErrorWithLine("Kernel failed!");	
}

void cudaUpdateVBO(float * vbodptr, float * nbodptr, int width, int height)
{
    dim3 fullBlocksPerGrid((int)ceil(float(numObjects)/float(blockSize)));
    sendToVBO<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, dev_vel, vbodptr, nbodptr, width, height, scene_scale);
    checkCUDAErrorWithLine("Kernel failed!");	  
}

void cudaUpdateVBOPre(float * vbodptr, int width, int height)
{
	dim3 fullBlocksPerGrid((int)ceil(float(numPredator)/float(blockSize)));
    sendToVBOPre<<<fullBlocksPerGrid, blockSize>>>(numPredator, pre_pos, pre_vel, vbodptr, width, height, scene_scale);
    checkCUDAErrorWithLine("Kernel failed!");	  
}