

# Copyright 2016 Vijayaditya Peddinti.
#           2016 Vimal Manohar
# Apache 2.0

""" This module contains several utility functions and classes that are
commonly used in many kaldi python scripts.
"""

import argparse
import logging
import math
import os
import subprocess
import threading

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setLevel(logging.INFO)
formatter = logging.Formatter("%(asctime)s [%(filename)s:%(lineno)s - "
                              "%(funcName)s - %(levelname)s ] %(message)s")
handler.setFormatter(formatter)
logger.addHandler(handler)


def send_mail(message, subject, email_id):
    try:
        subprocess.Popen(
            'echo "{message}" | mail -s "{subject}" {email}'.format(
                message=message,
                subject=subject,
                email=email_id), shell=True)
    except Exception as e:
        logger.info("Unable to send mail due to error:\n {error}".format(
                        error=str(e)))
        pass


def str_to_bool(value):
    if value == "true":
        return True
    elif value == "false":
        return False
    else:
        raise ValueError


class StrToBoolAction(argparse.Action):
    """ A custom action to convert bools from shell format i.e., true/false
        to python format i.e., True/False """

    def __call__(self, parser, namespace, values, option_string=None):
        try:
            setattr(namespace, self.dest, str_to_bool(values))
        except ValueError:
            raise Exception(
                "Unknown value {0} for --{1}".format(values, self.dest))


class NullstrToNoneAction(argparse.Action):
    """ A custom action to convert empty strings passed by shell to None in
    python. This is necessary as shell scripts print null strings when a
    variable is not specified. We could use the more apt None in python. """

    def __call__(self, parser, namespace, values, option_string=None):
        if values.strip() == "":
            setattr(namespace, self.dest, None)
        else:
            setattr(namespace, self.dest, values)


def check_if_cuda_compiled():
    p = subprocess.Popen("cuda-compiled")
    p.communicate()
    if p.returncode == 1:
        return False
    else:
        return True


class KaldiCommandException(Exception):

    def __init__(self, command, err):
        Exception.__init__(self,
                           "There was an error while running the command "
                           "{0}\n{1}\n{2}".format(command, "-"*10, err))


class ListNode():
    """ A structure to store a node in a doubly linked-list

    Attributes:
        data: Any object that is to be stored
        next_node: A reference to the next object
        previous_node: A reference to the previous object
    """

    def __init__(self, data=None, next_node=None, previous_node=None):
        self.data = data
        self.next_node = next_node
        self.previous_node = previous_node


class LinkedListIterator():

    def __init__(self, node):
        self.__current = node

    def __iter__(self):
        return self

    def next(self):
        if self.__current is None:
            raise StopIteration()

        node = self.__current
        self.__current = self.__current.next_node

        return node


class LinkedList():

    def __init__(self):
        self.__head = None
        self.__tail = None
        self.__size = 0

    def __iter__(self):
        return LinkedListIterator(self.__head)

    def push(self, node):
        """Pushes the node <node> at the "front" of the linked list
        """
        if self.__head == None:
            self.__head = node
            return
        node.next_node = self.__head
        node.previous_node = None
        self.__head.previous_node = node
        self.__head = node
        self.__size += 1

    def pop(self):
        """Pops the last node out of the list"""

        if self.__tail is None:
            return None

        old_last_node = self.__tail
        to_be_last = self.__tail.previous_node
        to_be_last.next_node = None
        old_last_node.previous_node = None

        # Set the last node to the "to_be_last"
        self.__tail = to_be_last
        self.__size -= 1

        return old_last_node

    def remove(self, node):
        """Removes and returns node, and connects the previous and next
        nicely
        """
        next_node = node.next_node
        previous_node = node.previous_node

        if previous_node is not None:
            previous_node.next_node = next_node

        if next_node is not None:
            next_node.previous_node = previous_node

        # Make it "free"
        node.next_node = node.previous_node = None
        self.__size -= 1

        return node

    def size():
        return self.__size

    def is_not_empty():
        return self.__size != 0

class BackgroundProcessHandler():
    """ This class handles background processes to ensure that a top-level
    script waits until all the processes end before exiting

    A top-level script is expected to instantiate an object of this class
    and pass it to all calls of run_kaldi_command that are to be run in the
    background. The background processes are queued and these are polled
    in a parallel thread at set interval to check for failures.
    The top-level script can ensure at the end ensure that all processes are
    completed before exiting.

    Attributes:
        __process_queue: Stores a list of process handles and command tuples

    """

    def __init__(self, polling_time=600):
        self.__process_queue = LinkedList()
        self.__polling_time = polling_time
        self.__timer = None
        self.__is_running = False

    def __run():
        self.__is_running = False
        if self.poll():
            self.start()

    def start(self):
        if not self.__is_running:
            self.__timer = Timer(self.__polling_time, self.__run())
            self.__timer.start()
            self.__is_running = True

    def stop(self):
        self.__timer.cancel()
        self.__is_running = False

    def poll(self):
        for n in self.__process_queue:
            if self.is_process_done(n.data):
                self.ensure_process_is_done(n)
        return self.__process_queue.is_not_empty()

    def add_process(self, t):
        """ Add a (process handle, command) tuple to the queue
        """
        self.__process_queue.push(ListNode(data=t))
        self.start()

    def is_process_done(self, t):
        p, command = t
        if p.poll() is None:
            return False
        return True

    def ensure_process_is_done(self, n):
        p, command = n.data
        logger.info("Waiting for process '{0}' to end".format(command))
        [stdout, stderr] = p.communicate()
        if p.returncode is not 0:
            raise KaldiCommandException(command, stderr)
        self.__process_queue.remove(n)

    def ensure_processes_are_done(self):
        for n in self.__process_queue:
            self.ensure_process_is_done(n)
        self.stop()

    def __del__(self):
        self.stop()


def run_kaldi_command(command, wait=True, background_process_handler=None):
    """ Runs commands frequently seen in Kaldi scripts. These are usually a
        sequence of commands connected by pipes, so we use shell=True.

    Args:
        background_process_handler: An object of the BackgroundProcessHandler
            class that is instantiated by the top-level script. If this is
            provided, then the created process handle is added to the object.
        wait: If True, wait until the process is completed. However, if the
            background_process_handler is provided, this option will be
            ignored and the process will be run in the background.
    """
    # logger.info("Running the command\n{0}".format(command))
    p = subprocess.Popen(command, shell=True,
                         stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)

    if background_process_handler is not None:
        wait = False
        background_process_handler.add_process((p, command))

    if wait:
        [stdout, stderr] = p.communicate()
        if p.returncode is not 0:
            raise KaldiCommandException(command, stderr)
        return stdout, stderr
    else:
        return p


def get_number_of_leaves_from_tree(alidir):
    [stdout, stderr] = run_kaldi_command(
        "tree-info {0}/tree 2>/dev/null | grep num-pdfs".format(alidir))
    parts = stdout.split()
    assert(parts[0] == "num-pdfs")
    num_leaves = int(parts[1])
    if num_leaves == 0:
        raise Exception("Number of leaves is 0")
    return num_leaves


def get_number_of_leaves_from_model(dir):
    [stdout, stderr] = run_kaldi_command(
        "am-info {0}/final.mdl 2>/dev/null | grep -w pdfs".format(dir))
    parts = stdout.split()
    # number of pdfs 7115
    assert(' '.join(parts[0:3]) == "number of pdfs")
    num_leaves = int(parts[3])
    if num_leaves == 0:
        raise Exception("Number of leaves is 0")
    return num_leaves


def get_number_of_jobs(alidir):
    try:
        num_jobs = int(open('{0}/num_jobs'.format(alidir)).readline().strip())
    except (IOError, ValueError) as e:
        raise Exception("Exception while reading the "
                        "number of alignment jobs: {0}".format(e.str()))
    return num_jobs


def get_ivector_dim(ivector_dir=None):
    if ivector_dir is None:
        return 0
    [stdout_val, stderr_val] = run_kaldi_command(
        "feat-to-dim --print-args=false "
        "scp:{dir}/ivector_online.scp -".format(dir=ivector_dir))
    ivector_dim = int(stdout_val)
    return ivector_dim


def get_feat_dim(feat_dir):
    [stdout_val, stderr_val] = run_kaldi_command(
        "feat-to-dim --print-args=false "
        "scp:{data}/feats.scp -".format(data=feat_dir))
    feat_dim = int(stdout_val)
    return feat_dim


def get_feat_dim_from_scp(feat_scp):
    [stdout_val, stderr_val] = run_kaldi_command(
        "feat-to-dim --print-args=false "
        "scp:{feat_scp} -".format(feat_scp=feat_scp))
    feat_dim = int(stdout_val)
    return feat_dim


def split_data(data, num_jobs):
    run_kaldi_command("utils/split_data.sh {data} {num_jobs}".format(
                        data=data,
                        num_jobs=num_jobs))


def read_kaldi_matrix(matrix_file):
    try:
        lines = map(lambda x: x.split(), open(matrix_file).readlines())
        first_field = lines[0][0]
        last_field = lines[-1][-1]
        lines[0] = lines[0][1:]
        lines[-1] = lines[-1][:-1]
        if not (first_field == "[" and last_field == "]"):
            raise Exception(
                "Kaldi matrix file has incorrect format, "
                "only text format matrix files can be read by this script")
        for i in range(len(lines)):
            lines[i] = map(lambda x: int(float(x)), lines[i])
        return lines
    except IOError:
        raise Exception("Error while reading the kaldi matrix file "
                        "{0}".format(matrix_file))


def write_kaldi_matrix(output_file, matrix):
    # matrix is a list of lists
    with open(output_file, 'w') as f:
        f.write("[ ")
        num_rows = len(matrix)
        if num_rows == 0:
            raise Exception("Matrix is empty")
        num_cols = len(matrix[0])

        for row_index in range(len(matrix)):
            if num_cols != len(matrix[row_index]):
                raise Exception("All the rows of a matrix are expected to "
                                "have the same length")
            f.write(" ".join(map(lambda x: str(x), matrix[row_index])))
            if row_index != num_rows - 1:
                f.write("\n")
        f.write(" ]")


def force_symlink(file1, file2):
    import errno
    try:
        os.symlink(file1, file2)
    except OSError as e:
        if e.errno == errno.EEXIST:
            os.remove(file2)
            os.symlink(file1, file2)


def compute_lifter_coeffs(lifter, dim):
    coeffs = [0] * dim
    for i in range(0, dim):
        coeffs[i] = 1.0 + 0.5 * lifter * math.sin(math.pi * i / float(lifter))

    return coeffs


def compute_idct_matrix(K, N, cepstral_lifter=0):
    matrix = [[0] * K for i in range(N)]
    # normalizer for X_0
    normalizer = math.sqrt(1.0 / float(N))
    for j in range(0, N):
        matrix[j][0] = normalizer
    # normalizer for other elements
    normalizer = math.sqrt(2.0 / float(N))
    for k in range(1, K):
        for n in range(0, N):
            matrix[n][
                k] = normalizer * math.cos(math.pi / float(N) * (n + 0.5) * k)

    if cepstral_lifter != 0:
        lifter_coeffs = compute_lifter_coeffs(cepstral_lifter, K)
        for k in range(0, K):
            for n in range(0, N):
                matrix[n][k] = matrix[n][k] / lifter_coeffs[k]

    return matrix


def write_idct_matrix(feat_dim, cepstral_lifter, file_path):
    # generate the IDCT matrix and write to the file
    idct_matrix = compute_idct_matrix(feat_dim, feat_dim, cepstral_lifter)
    # append a zero column to the matrix, this is the bias of the fixed affine
    # component
    for k in range(0, feat_dim):
        idct_matrix[k].append(0)
    write_kaldi_matrix(file_path, idct_matrix)