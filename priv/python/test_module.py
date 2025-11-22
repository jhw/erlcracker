"""
Test module for ErlCracker Common Test suite.

All functions receive JSON strings and return JSON strings.
ErlCracker handles encoding/decoding automatically.
"""

import json


def fibonacci(json_input):
    """Calculate the nth Fibonacci number.

    Input: integer n
    Output: integer (nth fibonacci number)
    """
    n = json.loads(json_input)

    def fib(x):
        if x <= 1:
            return x
        return fib(x - 1) + fib(x - 2)

    result = fib(n)
    return json.dumps(result)


def process_user(json_input):
    """Process user data and return enhanced version.

    Input: map with keys: id, name, email
    Output: map with processed data
    """
    user = json.loads(json_input)

    result = {
        'id': user['id'],
        'name': user['name'].upper(),
        'email': user['email'].lower(),
        'processed': True
    }

    return json.dumps(result)


def echo(json_input):
    """Echo back the input unchanged.

    Input: any JSON-serializable data
    Output: same data
    """
    data = json.loads(json_input)
    return json.dumps(data)


def slow_operation(json_input):
    """Simulate a slow operation for timeout testing.

    Input: integer (seconds to sleep)
    Output: string confirmation
    """
    import time
    seconds = json.loads(json_input)
    time.sleep(seconds)
    return json.dumps(f"Slept for {seconds} seconds")


def raise_error(json_input):
    """Raise an error for error handling testing.

    Input: string (error message)
    Output: raises ValueError
    """
    message = json.loads(json_input)
    raise ValueError(message)


def batch_sum(json_input):
    """Sum a list of numbers.

    Input: list of numbers
    Output: sum
    """
    numbers = json.loads(json_input)
    return json.dumps(sum(numbers))
