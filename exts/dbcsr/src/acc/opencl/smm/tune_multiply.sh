#!/usr/bin/env bash
####################################################################################################
# Copyright (C) by the DBCSR developers group - All rights reserved                                #
# This file is part of the DBCSR library.                                                          #
#                                                                                                  #
# For information on the license, see the LICENSE file.                                            #
# For further information please visit https://dbcsr.cp2k.org                                      #
# SPDX-License-Identifier: GPL-2.0+                                                                #
####################################################################################################

XARGS=$(command -v xargs)
SORT=$(command -v sort)
HEAD=$(command -v head)
SED=$(command -v gsed)
LS=$(command -v ls)
RM=$(command -v rm)
WC=$(command -v wc)

# initial delay before auto-tuning (interactive)
WAIT_DEFAULT=12

# GNU sed is desired (macOS)
if [ ! "${SED}" ]; then
  SED=$(command -v sed)
fi

if [ "${XARGS}" ] && [ "${SORT}" ] && [ "${HEAD}" ] && [ "${SED}" ] && \
   [ "${LS}" ] && [ "${RM}" ] && [ "${WC}" ];
then
  while test $# -gt 0; do
    case "$1" in
    -h|--help)
      HELP=1
      shift $#;;
    -c|--continue)
      CONTINUE=1
      shift 1;;
    -w|--wait)
      WAIT=$2
      shift 2;;
    -u|--update)
      UPDATE=1
      shift 1;;
    -a|--tuning-level)
      TLEVEL=$2
      shift 2;;
    -b|--backwards)
      REVERSE=1
      shift 1;;
    -t|--maxtime)
      MAXTIME=$2
      shift 2;;
    -p|--jsondir)
      JSONDIR=$2
      shift 2;;
    -k|--specid)
      SPECID=$2
      shift 2;;
    -m|--limit)
      MAXEXT=$2
      shift 2;;
    -n|--triplets)
      MAXNUM=$2
      shift 2;;
    -r|--bound)
      BOUNDL=$2
      BOUNDU=$3
      shift 3;;
    -i|--part)
      PART=$2
      shift 2;;
    -j|--nparts)
      NPARTS=$2
      shift 2;;
    -s|--batchsize)
      BATCHSIZE=$2
      shift 2;;
    *)
      break;;
    esac
  done
  if [ ! "${HELP}" ] || [ "0" = "${HELP}" ]; then
    ECHO=">&2 echo"
  else
    ECHO="echo"
  fi
  eval "${ECHO} \"Usage: $0 [options] [<triplet-spec>]\""
  eval "${ECHO} \"       Options must precede triplet specification\""
  eval "${ECHO} \"       -w|--wait N: initial delay before auto-tuning (default: ${WAIT_DEFAULT} s)\""
  eval "${ECHO} \"       -c|--continue: proceed with plan if tuning is interrupted\""
  eval "${ECHO} \"       -u|--update: retune all JSONs found in directory (see -p)\""
  eval "${ECHO} \"       -s|--batchsize N: Number of batched SMMs (a.k.a. stacksize)\""
  eval "${ECHO} \"       -a|--tuning-level N=0..3: all, most, some, least tunables\""
  eval "${ECHO} \"       -b|--backwards: tune in descending order of triplets\""
  eval "${ECHO} \"       -t|--maxtime N: number of seconds spent per kernel\""
  eval "${ECHO} \"       -p|--jsondir P: path to JSON-files (tuned params)\""
  eval "${ECHO} \"       -i|--part N (1-based): Nth session out of nparts\""
  eval "${ECHO} \"       -j|--nparts N: number of total sessions (see -i)\""
  eval "${ECHO} \"       -r|--bound L U: limit L**3 < MNK <= U**3\""
  eval "${ECHO} \"       -m|--limit N: limit any shape extent to N\""
  eval "${ECHO} \"       -n|--triplets N: limit number of triplet\""
  eval "${ECHO} \"       -k|--specid N: predefined triplets\""
  eval "${ECHO} \"        0-10: older to newer (larger), e.g.,\""
  eval "${ECHO} \"           0:  201 kernels\""
  eval "${ECHO} \"          10: 1266 kernels\""
  eval "${ECHO} \"       <triplet-spec>, e.g., 134 kernels\""
  eval "${ECHO} \"         23, 5 32 13 24 26, 4 9\""
  eval "${ECHO}"
  # default settings
  if [ ! "${BATCHSIZE}" ]; then BATCHSIZE=0; fi
  if [ ! "${JSONDIR}" ]; then JSONDIR=.; fi
  if [ ! "${TLEVEL}" ]; then TLEVEL=-1; fi
  if [ ! "${NPARTS}" ]; then NPARTS=1; fi
  if [ ! "${PART}" ]; then PART=1; fi
  # sanity checks
  if [ "0" != "$((NPARTS<PART))" ]; then
    >&2 echo "ERROR: part-number ${PART} is larger than the requested ${NPARTS} parts!"
    exit 1
  fi
  HERE=$(cd "$(dirname "$0")" && pwd -P)
  JSONS=$(${LS} -1 ${JSONDIR}/tune_multiply-*-*x*x*-*gflops.json 2>/dev/null)
  if [ "${SPECID}" ] && [ "$1" ]; then
    >&2 echo "ERROR: --specid and <triplet-spec> are mutual exclusive!"
    exit 1
  elif [ ! "${HELP}" ] || [ "0" = "${HELP}" ]; then
    if [ "${UPDATE}" ] && [ "0" != "${UPDATE}" ]; then
      if [ ! "${TLEVEL}" ] || [ "0" != "$((0>TLEVEL))" ]; then TLEVEL=1; fi
      if [ ! "${MAXTIME}" ]; then MAXTIME=160; fi
      MNKS=$(echo "${JSONS}" | ${SED} -n "s/.*tune_multiply-..*-\(..*x..*x.[^-]*\)-..*gflops\.json/\1/p" \
         | ${SORT} -u -n -tx -k1,1 -k2,2 -k3,3)
    elif [ "${SPECID}" ]; then
      MNKS=$(eval "${HERE}/../../acc_triplets.sh -k ${SPECID} 2>/dev/null")
    else
      MNKS=$(eval "${HERE}/../../acc_triplets.sh $* 2>/dev/null")
    fi
  else
    exit 0
  fi
  if [ "${MNKS}" ]; then
    if [ "${BOUNDL}" ] || [ "${BOUNDU}" ]; then
      if [ ! "${BOUNDL}" ]; then BOUNDL=0; elif [ ! "${BOUNDU}" ]; then BOUNDU=0; fi
      if [ "0" != "$((0<=BOUNDL))" ]; then
        for MNK in $(echo "${MNKS}" | ${SED} "s/x/*/g"); do
          S=$((MNK))
          if [ "0" != "$((BOUNDL<BOUNDU))" ]; then
            if [ "0" != "$((BOUNDL**3<S&&S<=BOUNDU**3))" ]; then TMP="${TMP} ${MNK}"; fi
          else
            if [ "0" != "$((BOUNDL**3<S))" ]; then TMP="${TMP} ${MNK}"; fi
          fi
        done
        MNKS=$(echo "${TMP}" | ${SED} "s/*/x/g")
      fi
    fi
    if [ "${MNKS}" ] && [ "${MAXEXT}" ] && [ "0" != "$((0<MAXEXT))" ]; then
      TMP=""
      for MNK in ${MNKS}; do
        for EXT in $(echo "${MNK}" | ${SED} "s/x/ /g"); do
          if [ "0" != "$((MAXEXT<EXT))" ]; then continue 2; fi
        done
        TMP="${TMP} ${MNK}"
      done
      MNKS=${TMP}
    fi
    if [ "${REVERSE}" ] && [ "0" != "${REVERSE}" ] && \
       [ "$(command -v tr)" ] && [ "$(command -v tac)" ];
    then
      MNKS=$(echo "${MNKS}" | tr ' ' '\n' | tac | tr '\n' ' '; echo)
    fi
    if [ "${MNKS}" ] && [ "${MAXNUM}" ] && [ "0" != "$((0<MAXNUM))" ]; then
      MNKS=$(echo "${MNKS}" | ${XARGS} -n1 | ${HEAD} -n"${MAXNUM}")
    fi
  fi
  NTRIPLETS=$(echo "${MNKS}" | ${WC} -w)
  if [ "0" != "$((0==NTRIPLETS))" ]; then
    if [ "${HELP}" ] || [ "0" = "${HELP}" ]; then exit 0; fi
    >&2 echo "ERROR: invalid or no <triplet-spec> given!"
    exit 1
  fi
  PARTSIZE=$(((NTRIPLETS+NPARTS-1)/NPARTS))
  PARTOFFS=$(((PART-1)*PARTSIZE))
  PARTSIZE=$((PARTSIZE<=(NTRIPLETS-PARTOFFS)?PARTSIZE:(NTRIPLETS-PARTOFFS)))
  if [ "0" != "$((NPARTS<=NTRIPLETS))" ]; then
    echo "Session ${PART} of ${NPARTS} part(s)."
  else
    echo "Session ${PART} of ${NPARTS} part(s). The problem is over-decomposed!"
  fi
  if [ "${MAXTIME}" ] && [ "0" != "$((0<MAXTIME))" ]; then
    HRS=$((MAXTIME*PARTSIZE/3600))
    MNS=$(((MAXTIME*PARTSIZE-HRS*3600+59)/60))
    echo "Tuning ${PARTSIZE} kernels in this session will take about" \
         "${MAXTIME}s per kernel and ${HRS}h${MNS}m in total."
    MAXTIME="--stop-after=${MAXTIME}"
  else
    echo "Tuning ${PARTSIZE} kernels will take an unknown time (no limit given)."
  fi
  NJSONS=$(echo "${JSONS}" | ${WC} -l)
  if [ "0" != "${NJSONS}" ]; then
    if [ ! "${UPDATE}" ] || [ "0" = "${UPDATE}" ]; then
      echo "Already found ${NJSONS} (unrelated?) JSON-files."
    fi
  elif [ -e tune_multiply.csv ]; then
    echo "No JSON file found but (unrelated?) tune_multiply.csv exists."
  fi
  if [ ! "${WAIT}" ]; then WAIT=${WAIT_DEFAULT}; fi
  if [ "0" != "$((0<WAIT))" ] && [ "$(command -v sleep)" ]; then
    echo
    echo "Tuning will start in ${WAIT} seconds. Hit CTRL-C to abort."
    sleep ${WAIT}
  fi
  N=0
  for MNK in ${MNKS}; do
    if [ "0" != "$((PARTOFFS<=N))" ]; then
      echo
      echo "[$((N-PARTOFFS+1))/${PARTSIZE}]: auto-tuning ${MNK}-kernel..."
      # avoid mixing database of previous results into new session
      ${RM} -rf ./opentuner.db
      eval "${HERE}/tune_multiply.py ${MNK} -p ${JSONDIR} -s ${BATCHSIZE} -a ${TLEVEL} ${MAXTIME}"
      RESULT=$?
      # environment var. CONTINUE allows to proceed with next kernel
      # even if tune_multiply.py returned non-zero exit code
      if [[ ("0" != "${RESULT}") && \
            ("${CONTINUE}" = "" \
          || "${CONTINUE}" = "0" \
          || "${CONTINUE}" = "no" \
          || "${CONTINUE}" = "false") ]];
      then
        exit ${RESULT}
      fi
    fi
    N=$((N+1))
  done
  if [ "${RESULT}" ]; then
    ${RM} -rf ./opentuner.db
  fi
else
  >&2 echo "ERROR: missing prerequisites!"
  exit 1
fi
