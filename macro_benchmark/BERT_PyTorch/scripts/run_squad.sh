#!/usr/bin/env bash

# Copyright (c) 2019 NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


echo "DATA_DIR: $DATA_DIR"
echo "WORK_DIR: $WORK_DIR"

#OUT_DIR=/results/SQuAD

#echo "Container nvidia build = " $NVIDIA_BUILD_ID

batch_size=${1:-"10"}
num_gpu=${2:-"1"}
max_steps=${3:-"200"}
epochs=${4:-"1.0"}
init_checkpoint=${5:-"$DATA_DIR/download/pytorch_pretrained_weights/uncased_L-24_H-1024_A-16/bert_model.pt"}
learning_rate=${6:-"3e-5"}
precision=${7:-"fp16"}
seed=${8:-"1"}
squad_dir=${9:-"$DATA_DIR/download/squad/v1.1"}
vocab_file=${10:-"$DATA_DIR/download/google_pretrained_weights/uncased_L-24_H-1024_A-16/vocab.txt"}
OUT_DIR=${11:-"$WORK_DIR/output/SQuAD"}
mode=${12:-"train"}
CONFIG_FILE=${13:-"$DATA_DIR/download/google_pretrained_weights/uncased_L-24_H-1024_A-16/bert_config.json"}

echo "out dir is $OUT_DIR"
mkdir -p $OUT_DIR
if [ ! -d "$OUT_DIR" ]; then
  echo "ERROR: non existing $OUT_DIR"
  exit 1
fi

use_fp16=""
if [ "$precision" = "fp16" ] ; then
  echo "fp16 activated!"
  use_fp16=" --fp16 "
fi

if [ "$num_gpu" = "1" ] ; then
  export CUDA_VISIBLE_DEVICES=0
  mpi_command=""
else
  unset CUDA_VISIBLE_DEVICES
  mpi_command=" -m torch.distributed.launch --nproc_per_node=$num_gpu"
fi

CMD="python  $mpi_command run_squad.py "
CMD+="--init_checkpoint=$init_checkpoint "
if [ "$mode" = "train" ] ; then
  CMD+="--do_train "
  CMD+="--train_file=$squad_dir/train-v1.1.json "
  CMD+="--train_batch_size=$batch_size "
elif [ "$mode" = "eval" ] ; then
  CMD+="--do_predict "
  CMD+="--predict_file=$squad_dir/dev-v1.1.json "
  CMD+="--predict_batch_size=$batch_size "
elif [ "$mode" = "prediction" ] ; then
  CMD+="--do_predict "
  CMD+="--predict_file=$squad_dir/dev-v1.1.json "
  CMD+="--predict_batch_size=$batch_size "
else
  CMD+=" --do_train "
  CMD+=" --train_file=$squad_dir/train-v1.1.json "
  CMD+=" --train_batch_size=$batch_size "
  CMD+="--do_predict "
  CMD+="--predict_file=$squad_dir/dev-v1.1.json "
  CMD+="--predict_batch_size=$batch_size "
fi
CMD+=" --do_lower_case "
# CMD+=" --old "
# CMD+=" --loss_scale=128 "
CMD+=" --bert_model=bert-large-uncased "
CMD+=" --learning_rate=$learning_rate "
CMD+=" --seed=$seed "
CMD+=" --num_train_epochs=$epochs "
CMD+=" --max_seq_length=384 "
CMD+=" --doc_stride=128 "
CMD+=" --output_dir=$OUT_DIR "
CMD+=" --vocab_file=$vocab_file "
CMD+=" --config_file=$CONFIG_FILE "
CMD+=" --max_steps=$max_steps "
CMD+=" $use_fp16"

LOGFILE=$OUT_DIR/logfile.txt
echo "$CMD |& tee $LOGFILE"
time $CMD |& tee $LOGFILE

#sed -r 's/
#|([A)/\n/g' $LOGFILE > $LOGFILE.edit

if [ "$mode" != "eval" ]; then
throughput=`cat $LOGFILE | grep -E 'Iteration.*[0-9.]+(it/s)' | tail -1 | egrep -o '[0-9.]+(s/it|it/s)' | head -1 | egrep -o '[0-9.]+'`
train_perf=$(awk 'BEGIN {print ('$throughput' * '$num_gpu' * '$batch_size')}')
echo " training throughput: $train_perf"
fi

if [ "$mode" != "train" ]; then
    if [ "$mode" != "prediction" ]; then
        python $squad_dir/evaluate-v1.1.py $squad_dir/dev-v1.1.json $OUT_DIR/predictions.json |& tee -a $LOGFILE
        eval_throughput=`cat $LOGFILE | grep Evaluating | tail -1 | awk -F ','  '{print $2}' | egrep -o '[0-9.]+' | head -1 | egrep -o '[0-9.]+'`
        eval_perf=$(awk 'BEGIN {print ('$eval_throughput' * '$num_gpu' * '$batch_size')}')
        echo " evaluation throughput: $eval_perf"
    fi
fi
