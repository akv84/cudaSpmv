#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <sstream>
#include <ctime>
#include <iomanip>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include "matrix/MatrixInput.h"
#include "util/data_input_stream.h"
#include "util/data_output_stream.h"
#include "util/timer.h"
#include "matrix/factory.h"
#include "util/vector_gen.h"
#include <sys/stat.h>
#include "parameters.h"

#define DEFAULT_VECTOR_VALUE 1

using namespace std;
Parameter app;

uint32_t block_size = 32, times = 1;
uint64_t seed = 1;
string matrix_path, vector_path, outfile;
vector<string> formats;
vector<uint32_t> start_rows, perm, revperm;
uint32_t num_rows, num_cols, cur=0, nnz;
bool rebuild = false, writeMatrixParts = false, DEBUG = false;

template <typename T>
void readVector(const char *file, thrust::host_vector<T> &v, uint32_t len){
    ifstream in;
    in.exceptions ( ifstream::failbit | ifstream::badbit );
    try {
        in.open(file);
        for (int i=0;i<len;i++) {
            T t; in >> t;
            v.push_back(t);
        }
    }catch(ifstream::failure e) {
        cout << "Exception opening/reading: " << file << endl;
        throw e;
    }
    in.close();
}

template <typename T>
struct MatrixFormatsHolder{
	vector<Matrix<T> *> vec;
	~MatrixFormatsHolder(){
		for(uint32_t i=0; i<vec.size(); i++){
			if(vec[i] != NULL){
				delete vec[i];
			}
		}
	}
};

void skipLines(MMFormatInput &in, uint32_t lines){
	for(uint32_t i=0; i<lines; i++){
		uint32_t nc, temp;
		in >> nc;
		for(uint32_t j=0; j<nc; j++){
			in >> temp;
		}
	}
}

template <typename T>
void print_result( T* v , thrust::host_vector<T> &hv) {
    thrust::device_ptr<T> d_ptr =  thrust::device_pointer_cast(v);
    thrust::copy(d_ptr, d_ptr+num_rows, hv.begin());
    ofstream out(outfile.c_str());
    for(uint32_t i=0; i<num_rows; i++){
        out << hv[revperm[i]] << endl;
    }
    out.close();
}

template <typename T>
void execute(){
    cudaSetDevice(app.gpu);
    ifstream f(matrix_path.c_str());
	MMFormatInput matrix_input(f, perm);

	num_rows = matrix_input.getNumRows();
    num_cols = matrix_input.getNumCols();
    nnz = matrix_input.getNNz();

    cout << num_rows << " " << num_cols << " " << nnz << " " << static_cast<double>(nnz)/num_rows << endl;
	
    thrust::host_vector<T> hv;
	//read vector
	if(!vector_path.empty()){
		hv.reserve(max(num_rows,num_cols));
		readVector(vector_path.c_str(), hv, num_cols);
	}else{
		//generateVector(hv, max(num_rows,num_cols));
        hv.resize(max(num_rows,num_cols), DEFAULT_VECTOR_VALUE);
	}
	
	if (DEBUG) cout << "Vector storage: " << hv.size() * sizeof(T) / 1024.0 / 1024.0 << " MB" << endl;
	
	MatrixFormatsHolder<T> mfh; 
	for(uint32_t i=0; i<formats.size(); i++){
		Matrix<T> *matrix = matrix_factory::getMatrixObject<T>(formats[i]);
		if(i>0){
			uint32_t nr = start_rows[i]-start_rows[i-1];
			cur += nr;
			mfh.vec.back()->set_num_rows(nr);
		}
		matrix->set_num_cols(num_cols);
		mfh.vec.push_back(matrix);			
	}

	if (cur >= num_rows) 
        throw ios::failure("Sum of rows > number of rows!");

	mfh.vec.back()->set_num_rows(num_rows - cur);
	uint32_t skip = 0;
	for(uint32_t i=0; i<mfh.vec.size(); i++){
		struct stat st_file_info;
		stringstream ss;
		ss << getFileName(matrix_path) << "-" << start_rows[i] << mfh.vec[i]->getCacheName();
		string s(ss.str());
		if(!rebuild && !stat(s.c_str(), &st_file_info)){
			ifstream inCache(s.c_str());
			if (DEBUG) cout<<"Reading cache from row " << start_rows[i] << endl;
			mfh.vec[i]->readCache(inCache);
			inCache.close();
			skip += mfh.vec[i]->get_num_rows();
		}else{
			skipLines(matrix_input, skip);
			skip = 0;
			if (DEBUG) cout << "Reading matrix from row " << start_rows[i] << endl;
			mfh.vec[i]->readMatrix(matrix_input, perm);
			ofstream outCache(s.c_str());
			if (DEBUG) cout << "Building cache... " << endl;
			mfh.vec[i]->buildCache(outCache);
			outCache.close();
		}
        mfh.vec[i]->transferToDevice();
	}
	f.close();

	double total = 0;
	for(uint32_t j=0; j<mfh.vec.size(); j++){
		double cur = mfh.vec[j]->memoryUsage()/1024.0/1024.0;
		total += cur;
	}
	
	thrust::device_vector<T> dv[2];
	dv[0].assign(hv.begin(), hv.end());
	dv[1].resize(hv.size(), 0);
	
	size_t free, dvTotal;
	cudaMemGetInfo	(&free,&dvTotal);
    if (DEBUG){
        cout << "Used device memory: " << (dvTotal-free)/1024.0/1024.0 << "MB" <<  endl;
        cout << "Free device memory: " << free/1024.0/1024.0 << "MB" << endl;
        cout << "Total device memory: " << dvTotal/1024.0/1024.0 << "MB" <<  endl;
    }		

	double parts_time[mfh.vec.size()];
    nnz = 0;
	for(uint32_t i=0; i<mfh.vec.size(); i++){
		parts_time[i] = 0;
        nnz += mfh.vec[i]->nonZeroes();
	}
		
    T* v = thrust::raw_pointer_cast(&dv[0][0]);
	T* r = thrust::raw_pointer_cast(&dv[1][0]);

    cudaStream_t streams[mfh.vec.size()];
    for (int j=0; j<mfh.vec.size(); j++) {
        cudaStreamCreate(&streams[j]);
    }
    

    Timer overall, part;
    overall.start();
	for(uint32_t i=0; i<times; i++){
		uint32_t cur_row = 0;
		for(uint32_t j=0; j<mfh.vec.size(); j++){
            if (DEBUG) part.start();
    		
            mfh.vec[j]->multiply(v, r+cur_row, streams[j]);
			cur_row += mfh.vec[j]->get_num_rows();

            if (DEBUG) {
    			cudaThreadSynchronize();
		    	parts_time[j] += part.stop();
                checkCUDAError("kernel call");
            }
		}
        cudaDeviceSynchronize();
        checkCUDAError("kernel call");
        swap(v, r);
	}

    double totalTime = overall.stop(); 

	cout << "Expected/Actual memory usage: " << (total + 2 * hv.size() * sizeof(T) / 1024.0 / 1024.0) << " / " << (dvTotal-free)/1024.0/1024.0 << " MB" << endl;
	stringstream stmp;
	stmp << sizeof(T)*8 << "b," << times <<"iter";
	cout << setw(15) << stmp.str() 
		 << setw(15) << "seconds" 
		 << setw(15) << "nnz" 
		 << setw(15) << "GFL/s" 
		 << setw(15) << "MB" 
		 << setw(15) << "B/nnz" 
		 << endl;

    if (DEBUG)	
	for(uint32_t j=0; j<mfh.vec.size(); j++){
		cout << setw(15) << (formats[j] + ":") 
			 << setw(15) << parts_time[j] 
			 << setw(15) << mfh.vec[j]->nonZeroes() 
			 << setw(15) << 2*mfh.vec[j]->nonZeroes()/(parts_time[j]*1000000000)*times 
			 << setw(15) << mfh.vec[j]->memoryUsage()/1024.0/1024.0 
			 << setw(15) << mfh.vec[j]->memoryUsage()/(double)mfh.vec[j]->nonZeroes() 
			 << endl;
	}

	cout << setw(15) << "Total:"
		 << setw(15) << totalTime 
		 << setw(15) << nnz 
		 << setw(15) << nnz*2/(totalTime*1000000000)*times 
		 << setw(15) << total 
		 << setw(15) << total*1024*1024/nnz 
		 << endl;

    if (outfile.length() > 0)
        print_result(v, hv);
	
}

void readInfo() {
    char infopath[255];

    sprintf(infopath, FORMAT_PERM, getFileName(matrix_path).c_str());    
    ifstream ifs(infopath);
    DataInputStream permif( ifs );
    permif.readVector( perm );
    uint32_t maxdim = perm.size();
    revperm.resize(maxdim);
    for (uint32_t i=0;i<maxdim;i++) {
        revperm[perm[i]] = i;
    }
    ifs.close();

    sprintf(infopath , FORMAT_OUTPUT, getFileName(matrix_path).c_str());
    if (DEBUG) cout << infopath << endl;
    ifs.open(infopath);
    int nformats;
    ifs >> nformats;
    if (DEBUG) cout << "Read " << nformats << endl;
    formats.resize(nformats);
    start_rows.resize(nformats);

    for (int i=0;i<nformats;i++) { 
        ifs >> formats[i];
        cout << formats[i] << " ";
    }
    cout << "|| " ;
    for (int i=0;i<nformats;i++) {
        ifs >> start_rows[i];
        cout << start_rows[i] << " ";
    }
    cout << endl;
     
    ifs.close();
}


int main(int argc, char* argv[]){
    try {
        Params param(argc, argv);
        app.init(param);

        param.getParamOptional("times", &times);
        param.getParamOptional("outfile", &outfile);
        cout << outfile << endl;

		srand(seed);

		if(!app.wdir.empty()){
			cout << "Changing working directory to " << app.wdir << endl;
			int r = chdir(app.wdir.c_str());
		}

        matrix_path = app.matrixFile;
        vector_path = app.vectorFile;
        readInfo();
        if (app.datatype == "float")
            execute<float>();
        else
            execute<double>();
				
	} catch(std::exception& e) {
        cerr << e.what() << endl;
        return 1;
    }  
	
	return 0;
}