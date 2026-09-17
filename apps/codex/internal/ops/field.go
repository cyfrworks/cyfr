// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package ops

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
)

// Field separates an omitted argument from its explicit zero value. Generated
// structs use omitzero so an unset field is absent from the wire object.
type Field[T any] struct {
	value   T
	present bool
}

// Value supplies an argument, including false, zero and empty values.
func Value[T any](value T) Field[T] { return Field[T]{value: value, present: true} }

// Null explicitly supplies null for a nullable argument.
func Null[T any]() Field[*T] { return Value[*T](nil) }

// Nullable supplies a non-null value for a nullable argument.
func Nullable[T any](value T) Field[*T] { return Value(&value) }

// IsZero is used by encoding/json's omitzero field option.
func (field Field[T]) IsZero() bool { return !field.present }

// MarshalJSON encodes the supplied value. Omission is handled by its parent.
func (field Field[T]) MarshalJSON() ([]byte, error) { return json.Marshal(field.value) }

// UnmarshalJSON preserves explicit presence when reading typed JSON arguments.
func (field *Field[T]) UnmarshalJSON(data []byte) error {
	var value T
	if err := checkNulls(data, reflect.TypeFor[T]()); err != nil {
		return err
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*field = Value(value)
	return nil
}

// decodeRecord checks JSON presence before Go decoding can turn a missing or
// null scalar into its zero value. Field tags come from generated declarations.
func decodeRecord(data []byte, target any) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw == nil {
		return fmt.Errorf("arguments must be an object")
	}
	typ := reflect.TypeOf(target).Elem()
	allowed := make(map[string]bool, typ.NumField())
	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		tag := field.Tag.Get("json")
		if tag == "" || tag == "-" {
			continue
		}
		name, optional := tag, false
		if at := bytes.IndexByte([]byte(tag), ','); at >= 0 {
			name, optional = tag[:at], true
		}
		allowed[name] = true
		value, present := raw[name]
		if !present && !optional {
			return fmt.Errorf("missing required field: %s", name)
		}
		if present && !optional {
			if err := checkNulls(value, field.Type); err != nil {
				return fmt.Errorf("field %s: %w", name, err)
			}
		}
	}
	for name := range raw {
		if !allowed[name] {
			return fmt.Errorf("unknown argument field: %s", name)
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

// Go's decoder accepts null for scalars, including collection elements. Refuse
// it before decoding so invalid input cannot silently become an allowed zero.
func checkNulls(data []byte, typ reflect.Type) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		if typ.Kind() != reflect.Pointer && typ.Kind() != reflect.Interface {
			return fmt.Errorf("null is not allowed for this argument")
		}
		return nil
	}
	switch typ.Kind() {
	case reflect.Pointer:
		return checkNulls(data, typ.Elem())
	case reflect.Slice:
		var values []json.RawMessage
		if err := json.Unmarshal(data, &values); err != nil {
			return err
		}
		for _, value := range values {
			if err := checkNulls(value, typ.Elem()); err != nil {
				return err
			}
		}
	case reflect.Map:
		var values map[string]json.RawMessage
		if err := json.Unmarshal(data, &values); err != nil {
			return err
		}
		for _, value := range values {
			if err := checkNulls(value, typ.Elem()); err != nil {
				return err
			}
		}
	}
	return nil
}
