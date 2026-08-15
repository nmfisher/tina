/// Composable predicate filters for repository listings.
library;

/// A predicate over entities of type [T], composable with `and`/`or`/`not`.
extension type const Filter<T>(bool Function(T value) _test) {
  bool test(T value) => _test(value);

  Filter<T> and(Filter<T> other) => Filter<T>((v) => test(v) && other.test(v));

  Filter<T> or(Filter<T> other) => Filter<T>((v) => test(v) || other.test(v));

  Filter<T> operator ~() => Filter<T>((v) => !test(v));

  static Filter<T> always<T>() => Filter<T>((_) => true);

  static Filter<T> never<T>() => Filter<T>((_) => false);
}

/// Applies [filter] to [values], preserving order.
List<T> whereFilter<T>(List<T> values, Filter<T> filter) =>
    values.where(filter.test).toList();
