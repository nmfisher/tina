/// A `Result` type for operations that fail without throwing.
library;

/// Either a value of type [T] or an [Err] carrying [E].
sealed class Result<T, E> {
  const Result();

  const factory Ok(T value) = Ok._;
  const factory Err(E error) = Err._;

  /// Maps the success value, passing failures through unchanged.
  Result<R, E> map<R>(R Function(T value) transform) => switch (this) {
    Ok(value: final v) => Ok(transform(v)),
    Err() => this as Result<R, E>,
  };

  /// Runs [transform] on the error, passing successes through unchanged.
  Result<T, F> mapErr<F>(F Function(E error) transform) => switch (this) {
    Ok() => this as Result<T, F>,
    Err(error: final e) => Err(transform(e)),
  };

  /// Returns the success value, or [fallback] if this is an [Err].
  T unwrapOr(T fallback) => switch (this) {
    Ok(value: final v) => v,
    Err() => fallback,
  };
}

final class Ok<T, E> extends Result<T, E> {
  const Ok._(this.value);

  final T value;
}

final class Err<T, E> extends Result<T, E> {
  const Err._(this.error);

  final E error;
}
